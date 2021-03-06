#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <signal.h>
#include <assert.h>

#include "mtask.h"

#include "mtask_imp.h"
#include "mtask_env.h"
#include "mtask_server.h"
#include "luashrtbl.h"

static int
optint(const char *key, int opt)
{
	const char * str = mtask_getenv(key);
	if (str == NULL) {
		char tmp[20];
		sprintf(tmp,"%d",opt);
		mtask_setenv(key, tmp);
		return opt;
	}
	return (int)strtol(str, NULL, 10);
}


static int
optboolean(const char *key, int opt)
{
	const char * str = mtask_getenv(key);
	if (str == NULL) {
		mtask_setenv(key, opt ? "true" : "false");
		return opt;
	}
	return strcmp(str,"true")==0;
}


static const char *
optstring(const char *key,const char * opt)
{
	const char * str = mtask_getenv(key);
	if (str == NULL) {
		if (opt) {
			mtask_setenv(key, opt);
			opt = mtask_getenv(key);
		}
		return opt;
	}
	return str;
}

static void
_init_env(lua_State *L)
{
	lua_pushnil(L);  /* first key 1是栈顶位置 */
    //从栈上弹出一个 key（键）,然后把索引指定的表中 key-value（健值）对压入堆栈（指定key后面的下一 (next)对）.
	while (lua_next(L, -2) != 0) {
        //如果表中已经没有更多元素,lua_next将返回0
		int keyt = lua_type(L, -2);//key的类型
		if (keyt != LUA_TSTRING) {
			fprintf(stderr, "Invalid config table\n");
			exit(1);
		}
		const char * key = lua_tostring(L,-2); //取出key
		if (lua_type(L,-1) == LUA_TBOOLEAN) {  //判断value的类型
			int b = lua_toboolean(L,-1);       //取出值
			mtask_setenv(key,b ? "true" : "false" );
		} else {
			const char * value = lua_tostring(L,-1);//取出value
			if (value == NULL) {
				fprintf(stderr, "Invalid config table key = %s\n", key);
				exit(1);
			}
			mtask_setenv(key,value); //设置环境 G[key] = value
		}
		lua_pop(L,1);//移除value 保留key 方便lua_next做下一次循环 lua_next会移除key
	}
	lua_pop(L,1);
}
//服务端例行代码 忽略信号
//如果尝试send到一个disconnected socket上，就会让底层抛出一个SIGPIPE信号。这个信号的缺省处理方法是退出进程
int
sigign()
{
	struct sigaction sa;
	sa.sa_handler = SIG_IGN;
    sa.sa_flags = 0;
    sigemptyset(&sa.sa_mask);
	sigaction(SIGPIPE, &sa, 0);
	return 0;
}

static const char * load_config = "\
    local result = {}\n\
    local function getenv(name) return assert(os.getenv(name), [[os.getenv() failed: ]] .. name) end\n\
    local sep = package.config:sub(1,1)\n\
    local current_path = [[.]]..sep\n\
    local function include(filename)\n\
        local last_path = current_path\n\
        local path, name = filename:match([[(.*]]..sep..[[)(.*)$]])\n\
        if path then\n\
            if path:sub(1,1) == sep then	-- root\n\
                current_path = path\n\
            else\n\
                current_path = current_path .. path\n\
            end\n\
        else\n\
            name = filename\n\
        end\n\
        local f = assert(io.open(current_path .. name))\n\
        local code = assert(f:read [[*a]])\n\
        code = string.gsub(code, [[%$([%w_%d]+)]], getenv)\n\
        f:close()\n\
        assert(load(code,[[@]]..filename,[[t]],result))()\n\
        current_path = last_path\n\
    end\n\
    setmetatable(result, { __index = { include = include } })\n\
    local config_name = ...\n\
    include(config_name)\n\
    setmetatable(result, nil)\n\
    return result\n\
";

int
main(int argc, char *argv[])
{
	const char * config_file = NULL ;
	if (argc > 1) {
		config_file = argv[1];//argv[0] 是程序全名
	} else {
		fprintf(stderr, "Need a config file.\n"
			"usage: mtask configfilename\n");
		return 1;
	}
    luaS_initshr();
	mtask_global_init(); //初始化mtask_node  G_NODE 结构设置线程局部存储值为main_thread
	mtask_env_init();   //初始化mtask_env   E      new 了一个lua_state(虚拟机)
 
	sigign();           //忽略signpipe信号

	struct mtask_config config;

	struct lua_State *L = luaL_newstate();
	luaL_openlibs(L);	// link lua lib
    
    int err =  luaL_loadbufferx(L, load_config, strlen(load_config), "=[mtask config]", "t");
	assert(err == LUA_OK);
	lua_pushstring(L, config_file);
    //调用栈上的函数 参数格式1 返回值1 错误捕函数为空
	err = lua_pcall(L, 1, 1, 0);
	if (err) {
		fprintf(stderr,"%s\n",lua_tostring(L,-1));
		lua_close(L);
		return 1;
	}
	_init_env(L);
    //设置获取mtask_env中的key-value  并且初始化mtask_config
    config.thread =  optint("thread",8);//工作线程数量
	config.module_path = optstring("cpath","./cservice/?.so");//C 编写的服务模块的位置,通常指 cservice 下那些 .so
	config.harbor = optint("harbor", 1);//节点编号 可以是 1-255 间的任意整数
	config.bootstrap = optstring("bootstrap","snlua bootstrap");//启动的第一个服务以及其启动参数
	config.daemon = optstring("daemon", NULL);//后台模式启动
	config.logger = optstring("logger", NULL);//日志文件
	config.logservice = optstring("logservice", "logger");//log服务
    config.profile = optboolean("profile", 1);  //性能统计

	lua_close(L);//关闭掉新创建的lua_state

	mtask_start(&config);//启动 mtask
	mtask_global_exit(); //设置G_NODE 中线程局部存储的key （删除pthread_key）
    luaS_exitshr();
    
	return 0;
}
