#include <stdlib.h>
#include <assert.h>
#include <lua.h>
#include <lauxlib.h>

#include "mtask.h"
#include "mtask_env.h"
#include "mtask_spinlock.h"

//mtask 环境保存lua虚拟机
struct mtask_env {
	spinlock_t lock; //互斥锁
	lua_State *L;         //lua VM
};
// mtask 环境配置 主要是获取和设置lua的环境变量
static struct mtask_env *E = NULL;
//获取mtask环境变量
const char *
mtask_getenv(const char *key)
{
	SPIN_LOCK(E)

	lua_State *L = E->L;
	
	lua_getglobal(L, key);//获取_G[key]放在栈顶
	const char * result = lua_tostring(L, -1);// 去除栈顶数据 _G[key]
	lua_pop(L, 1);//弹出栈顶一个值

	SPIN_UNLOCK(E)

	return result;
}
//设置mtask环境变量
void 
mtask_setenv(const char *key, const char *value)
{
	SPIN_LOCK(E)
	
	lua_State *L = E->L;
	lua_getglobal(L, key);
	assert(lua_isnil(L, -1));
	lua_pop(L,1);
	lua_pushstring(L,value);//value 字符串入栈
	lua_setglobal(L,key);//栈顶元素出栈 设置为G[key] = value的值。

	SPIN_UNLOCK(E)
}
//环境初始化 创建一个lua虚拟机

void
mtask_env_init()
{
	E = mtask_malloc(sizeof(*E));
	SPIN_INIT(E)
	E->L = luaL_newstate();
}
