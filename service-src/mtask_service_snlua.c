#include "mtask.h"

#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include <assert.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

//snlu.so
// lua 服务生成器
// lua服务的消息　先到 service_snlua，再分发到lua服务中
// 每个lua服务其实　是一个service_snlua + 实际的lua服务　总和
//mtask_start中调用bootstrap(ctx, config->bootstrap); //创建snlua服务模块，及ctx
//参数为 snlua bootstrap

#define MEMORY_WARNING_REPORT (1024 * 1024 * 32)

struct snlua {
	lua_State * L;
	struct mtask_context * ctx;//服务的mtask_context结构
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
	else {
		lua_pushliteral(L, "(no error message)");
	}
	return 1;
}

static void
report_launcher_error(struct mtask_context *ctx)
{
	// sizeof "ERROR" == 5
	mtask_sendname(ctx, 0, ".launcher", PTYPE_TEXT, 0, "ERROR", 5);
}

static const char *
optstring(struct mtask_context *ctx, const char *key, const char * str)
{
	const char * ret = mtask_command(ctx, "GETENV", key);
	if (ret == NULL) {
		return str;
	}
	return ret;
}

static int
_init_cb(struct snlua *l, struct mtask_context *ctx, const char * args, size_t sz)
{
    lua_State *L = l->L;
    l->ctx = ctx;
    lua_gc(L, LUA_GCSTOP, 0); //停止垃圾回收
    lua_pushboolean(L, 1); //放个nil到栈上 /* signal for libraries to ignore env. vars. */
    lua_setfield(L, LUA_REGISTRYINDEX, "LUA_NOENV");
    luaL_openlibs(L);
    lua_pushlightuserdata(L, ctx); //服务的ctx放到栈上
    lua_setfield(L, LUA_REGISTRYINDEX, "mtask_context"); //_G[REGISTER_INDEX]["mtask_context"] = L[1] 将ctx放在注册表中
    luaL_requiref(L, "mtask.codecache", codecache , 0); //package.load[mtask.codecache]没有的话则调用codecache[mtask.codecache]
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
    
    int r = luaL_loadfile(L,loader); //加载loader.lua
    if (r != LUA_OK) {
        mtask_error(ctx, "Can't load %s : %s", loader, lua_tostring(L, -1));
        report_launcher_error(ctx);
        return 1;
    }
    lua_pushlstring(L, args, sz);
    r = lua_pcall(L,1,0,1);
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
//snlua 服务受到消息时的处理
static int
_launch_cb(struct mtask_context * context, void *ud, int type, int session, uint32_t source , const void * msg, size_t sz)
{
	assert(type == 0 && session == 0);
	struct snlua *l = ud;
	mtask_callback(context, NULL, NULL);//初始服务的回调
	int err = _init_cb(l, context, msg, sz);
	if (err) {
		mtask_command(context, "EXIT", NULL);
	}

	return 0;
}
//mtask_context_new 创建snlua服务会调用 create init
int
snlua_init(struct snlua *l, struct mtask_context *ctx, const char * args)
{
	int sz = (int)strlen(args);
	char * tmp = mtask_malloc(sz);
	memcpy(tmp, args, sz);
	mtask_callback(ctx, l , _launch_cb);//注册snlua的回到哦函数为launch_cb
	const char * self = mtask_command(ctx, "REG", NULL);//服务注册名字 “:handle”
	uint32_t handle_id = (uint32_t)strtoul(self+1, NULL, 16);
	// it must be first message 给他自己发送一个信息，目的地为刚注册的地址，最终将该消息push到对应的mq上
	mtask_send(ctx, 0, handle_id, PTYPE_TAG_DONTCOPY,0, tmp, sz);
	return 0;
}

struct snlua *
snlua_create(void)
{
	struct snlua * l = mtask_malloc(sizeof(*l));
	memset(l,0,sizeof(*l));
	l->L = lua_newstate(mtask_lalloc, NULL);//生成新的lua_state 放到snlua的l中
    l->mem_report = MEMORY_WARNING_REPORT;
    l->mem_limit = 0;
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