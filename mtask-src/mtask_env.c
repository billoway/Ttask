#include "mtask.h"
#include "mtask_env.h"
#include "mtask_spinlock.h"

#include <lua.h>
#include <lauxlib.h>

#include <stdlib.h>
#include <assert.h>

struct mtask_env {
	struct spinlock lock;
	lua_State *L;
};

static struct mtask_env *E = NULL;

const char * 
mtask_getenv(const char *key) {
	SPIN_LOCK(E)

	lua_State *L = E->L;
	
	lua_getglobal(L, key);
	const char * result = lua_tostring(L, -1);
	lua_pop(L, 1);

	SPIN_UNLOCK(E)

	return result;
}

void 
mtask_setenv(const char *key, const char *value) {
	SPIN_LOCK(E)
	
	lua_State *L = E->L;
	lua_getglobal(L, key);
	assert(lua_isnil(L, -1));
	lua_pop(L,1);
	lua_pushstring(L,value);
	lua_setglobal(L,key);

	SPIN_UNLOCK(E)
}

void
mtask_env_init() {
	E = mtask_malloc(sizeof(*E));
	SPIN_INIT(E)
	E->L = luaL_newstate();
}
