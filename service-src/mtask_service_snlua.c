#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include <assert.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

#include "mtask.h"


// snlua.so
// lua 服务生成器
// lua服务的消息　先到 service_snlua，再分发到lua服务中
// 每个lua服务其实　是一个service_snlua + 实际的lua服务　总和

//服务创建都是通过 mtask_context_new来进行的，mtask_context_new 必然会创建一个C模块(或者从已有C模块中找到已创建的模块)。
// C服务的创建可以简单的说是加载这个模块，执行一些初始化工作，然后注册消息处理函数就完毕了。
// lua服务的创建与 C 服务则有不同，它是通过snlua来创建的，每个lua服务的第一消息必然是发给自己的，
// 而且这个消息的处理函数是 snlua 模块在执行 snlua_init 时注册的，当一个lua服务收到第一个消息时，
// 是通过 loader.lua 来加载自己，并重新注册处理函数的。
// 注:并不存在什么 snlua 服务，它只是创建lua服务的一个中间过程而已。

// mtask_start中调用bootstrap(ctx, config->bootstrap) 是snlua 启动的第一个Lua 服务;
// 创建snlua服务模块，及ctx 参数为 snlua bootstrap
#define MEMORY_WARNING_REPORT (1024 * 1024 * 32)

struct snlua {
	lua_State * L;
	mtask_context_t * ctx;//服务的mtask_context结构
    size_t mem;
    size_t mem_report;
    size_t mem_limit;
};

// LUA_CACHELIB may defined in patched lua for shared proto
#ifdef LUA_CACHELIB

#define codecache luaopen_cache

#else

static int
cleardummy(lua_State *L)
{
  return 0;
}

static int
codecache(lua_State *L) {
    luaL_Reg l[] = {
        { "clear", cleardummy },
        { "mode", cleardummy },
        { NULL, NULL },
    };
    luaL_newlib(L,l);  //创建一个新表 将clear和mode函数注册进去
    lua_getglobal(L, "loadfile");   //_G["loadfile"] 入栈
    lua_setfield(L, -2, "loadfile"); //L[-2][loadfile] = L[-1] 相当于把 loadfiel注册到新建的表中
    return 1;
}

#endif

static int 
traceback (lua_State *L)
{
	const char *msg = lua_tostring(L, 1);
	if (msg)
		luaL_traceback(L, L, msg, 1);
	else
		lua_pushliteral(L, "(no error message)");
	return 1;
}

static void
report_launcher_error(mtask_context_t *ctx)
{
	// sizeof "ERROR" == 5
	mtask_sendname(ctx, 0, ".launcher", PTYPE_TEXT, 0, "ERROR", 5);
}

static const char *
optstring(mtask_context_t *ctx, const char *key, const char * str)
{
	const char * ret = mtask_command(ctx, "GETENV", key);
	if (ret == NULL) {
		return str;
	}
	return ret;
}

static int
_init_cb(struct snlua *l, mtask_context_t *ctx, const char * args, size_t sz)
{
    lua_State *L = l->L;
    l->ctx = ctx;
    lua_gc(L, LUA_GCSTOP, 0); //停止垃圾回收
    lua_pushboolean(L, 1); //放个nil到栈上
    /* signal for libraries to ignore env. vars. */
    lua_setfield(L, LUA_REGISTRYINDEX, "LUA_NOENV");
    luaL_openlibs(L);
    lua_pushlightuserdata(L, ctx); //服务的ctx放到栈上
    //_G[REGISTER_INDEX]["mtask_context"] = L[1] 将ctx放在注册表中
    lua_setfield(L, LUA_REGISTRYINDEX, "mtask_context");
    //package.load[mtask.codecache]没有的话则调用codecache[mtask.codecache]
    luaL_requiref(L, "mtask.codecache", codecache , 0);
    lua_pop(L,1);
    
    //设置环境变量 LUA_PATH  LUA_CPATH  LUA_SERVICE  LUA_PRELOAD
    const char *path = optstring(ctx, "lua_path","./lualib/?.lua;./lualib/?/init.lua");
    lua_pushstring(L, path);
    lua_setglobal(L, "LUA_PATH");
    const char *cpath = optstring(ctx, "lua_cpath","./luaclib/?.so");
    lua_pushstring(L, cpath);
    lua_setglobal(L, "LUA_CPATH");
    const char *service = optstring(ctx, "luaservice", "./service/?.lua");
    lua_pushstring(L, service);
    lua_setglobal(L, "LUA_SERVICE");
    const char *preload = mtask_command(ctx, "GETENV", "preload");
    lua_pushstring(L, preload);
    lua_setglobal(L, "LUA_PRELOAD");
    
    // 设置了栈回溯函数
    lua_pushcfunction(L, traceback);
    assert(lua_gettop(L) == 1);
    
    const char * loader = optstring(ctx, "lualoader", "./lualib/loader.lua");
    //加载loader.lua(把 loader.lua 作为一个lua函数压到栈顶)
    int r = luaL_loadfile(L,loader); //Lua stack + 1 = 2
    if (r != LUA_OK) {
        mtask_error(ctx, "Can't load %s : %s", loader, lua_tostring(L, -1));
        report_launcher_error(ctx);
        return 1;
    }
    lua_pushlstring(L, args, sz); //Lua stack + 1 = 3
    // 调用 loader.lua 生成的代码块
    r = lua_pcall(L,1,0,1);//[-(nargs + 1), +(nresults|1), Lua stack = 1
    if (r != LUA_OK) {
        mtask_error(ctx, "lua loader error : %s", lua_tostring(L, -1));
        report_launcher_error(ctx);
        return 1;
    }
    lua_settop(L,0);
    if (lua_getfield(L, LUA_REGISTRYINDEX, "memlimit") == LUA_TNUMBER) {
        size_t limit = lua_tointeger(L, -1);
        l->mem_limit = limit;
        mtask_error(ctx, "Set memory limit to %.2f M", (float)limit / (1024 * 1024));
        lua_pushnil(L);
        lua_setfield(L, LUA_REGISTRYINDEX, "memlimit");
    }
    lua_pop(L, 1);
    
    lua_gc(L, LUA_GCRESTART, 0);
    
    return 0;
}
//当worker线程调度到这个消息时便会执行
static int
_launch_cb(mtask_context_t * context, void *ud, int type, int session, uint32_t source , const void * msg, size_t sz)
{
	assert(type == 0 && session == 0);
	struct snlua *l = ud;
    // 将消息处理函数置空，以免别的消息发过来
	mtask_callback(context, NULL, NULL);
    // 消息处理:通过 loader.lua 加载 lua 代码块
	int err = _init_cb(l, context, msg, sz);
	if (err) {
		mtask_command(context, "EXIT", NULL);
	}

	return 0;
}
//mtask_context_new 创建snlua服务会调用 create init
int
snlua_init(struct snlua *l, mtask_context_t *ctx, const char * args)
{
	int sz = (int)strlen(args);
	char * tmp = mtask_malloc(sz);
	memcpy(tmp, args, sz);
	mtask_callback(ctx, l , _launch_cb);//注册snlua的回调函数为launch_cb
	const char * self = mtask_command(ctx, "REG", NULL);//服务注册名字 “:handle”
	uint32_t handle_id = (uint32_t)strtoul(self+1, NULL, 16);
	// it must be first message 给他自己发送一个信息，目的地为刚注册的地址，最终将该消息push到对应的mq上
    // 发消息给自己 以便加载相应的服务模块 tmp为 具体的 lua 服务脚本
	mtask_send(ctx, 0, handle_id, PTYPE_TAG_DONTCOPY,0, tmp, sz);
	return 0;
}

static void *
lalloc(void * ud, void *ptr, size_t osize, size_t nsize)
{
    struct snlua *l = ud;
    size_t mem = l->mem;
    l->mem += nsize;
    if (ptr)
        l->mem -= osize;
    if (l->mem_limit != 0 && l->mem > l->mem_limit) {
        if (ptr == NULL || nsize > osize) {
            l->mem = mem;
            return NULL;
        }
    }
    if (l->mem > l->mem_report) {
        l->mem_report *= 2;
        mtask_error(l->ctx, "Memory warning %.2f M", (float)l->mem / (1024 * 1024));
    }
    return mtask_lalloc(ptr, osize, nsize);
}

struct snlua *
snlua_create(void)
{
    struct snlua * l = mtask_malloc(sizeof(*l));
    memset(l,0,sizeof(*l));
    l->mem_report = MEMORY_WARNING_REPORT;
    l->mem_limit = 0;
    l->L = lua_newstate(lalloc, l);
    return l;
}

void
snlua_release(struct snlua *l)
{
	lua_close(l->L);//关闭snlua中的lua_state
	mtask_free(l);
}

void
snlua_signal(struct snlua *l, int signal)
{
	mtask_error(l->ctx, "recv a signal %d", signal);
    if (signal == 0) {
#ifdef lua_checksig
        // If our lua support signal (modified lua version by mtask), trigger it.
        mtask_sig_L = l->L;
#endif
    } else if (signal == 1) {
        mtask_error(l->ctx, "Current Memory %.3fK", (float)l->mem / 1024);
    }
}
