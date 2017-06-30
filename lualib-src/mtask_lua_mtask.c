#include "mtask.h"
#include "mtask_lua_seri.h"

#define KNRM  "\x1B[0m"
#define KRED  "\x1B[31m"

#include <lua.h>
#include <lauxlib.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

//核心库，封装mtask给lua使用  mtask.so

struct snlua {
	lua_State * L;
	struct mtask_context * ctx;
	const char * preload;
};

static int
traceback (lua_State *L)
{
	const char *msg = lua_tostring(L, 1);
	if (msg) //将栈L的栈回溯信息压栈;msg它会附加到栈回溯信息之前,从第一层开始做展开回溯。
		luaL_traceback(L, L, msg, 1);
	else {
		lua_pushliteral(L, "(no error message)");
	}
	return 1;
}

static int
_cb(struct mtask_context * context, void * ud, int type, int session, uint32_t source, const void * msg, size_t sz)
{
	lua_State *L = ud;
	int trace = 1;
	int r;
	int top = lua_gettop(L);
	if (top == 0) {
		lua_pushcfunction(L, traceback);
		lua_rawgetp(L, LUA_REGISTRYINDEX, _cb);
	} else {
		assert(top == 2);
	}
	lua_pushvalue(L,2);

	lua_pushinteger(L, type);
	lua_pushlightuserdata(L, (void *)msg);
	lua_pushinteger(L,sz);
	lua_pushinteger(L, session);
	lua_pushinteger(L, source);

	r = lua_pcall(L, 5, 0 , trace);

	if (r == LUA_OK) {
		return 0;
	}
	const char * self = mtask_command(context, "REG", NULL);
	switch (r) {
	case LUA_ERRRUN:
		mtask_error(context, "lua call [%x to %s : %d msgsz = %d] error : " KRED "%s" KNRM, source , self, session, sz, lua_tostring(L,-1));
		break;
	case LUA_ERRMEM:
		mtask_error(context, "lua memory error : [%x to %s : %d]", source , self, session);
		break;
	case LUA_ERRERR:
		mtask_error(context, "lua error in error : [%x to %s : %d]", source , self, session);
		break;
	case LUA_ERRGCMM:
		mtask_error(context, "lua gc error : [%x to %s : %d]", source , self, session);
		break;
	};

	lua_pop(L,1);

	return 0;
}

static int
forward_cb(struct mtask_context * context, void * ud, int type, int session, uint32_t source, const void * msg, size_t sz)
{
	_cb(context, ud, type, session, source, msg, sz);
	// don't delete msg in forward mode.
	return 1;
}
//设置mtask_context总的cb和cb_ud 分别为_cb何lua_state 同时记录lua_function到注册表中
static int
_callback(lua_State *L)
{
	struct mtask_context * context = lua_touserdata(L, lua_upvalueindex(1));
	int forward = lua_toboolean(L, 2);//是否转发
	luaL_checktype(L,1,LUA_TFUNCTION);//检测栈底是否为lua_function
	lua_settop(L,1);    //删除栈底之后的栈
	lua_rawsetp(L, LUA_REGISTRYINDEX, _cb);
    //等价于 t[k] = v ， 这里的 t 是指给定索引处的表， k 是指针 p 对应的轻量用户数据。 而 v 是栈顶的值。
    //void lua_rawsetp (lua_State *L, int index, const void *p);
    //_G[LUA_REGISTRYINDEX] [_cb] = L[1], 相当于将栈顶出的函数设置在注册表中，并且使用_cb作为key L[1]出栈
    
    //LUA_RIDX_MAINTHREAD 注册表中这个索引下是状态机的主线程
	lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_MAINTHREAD);//G[LUA_REGISTRYINDEX][LUA_RIDX_MAINTHREAD]值入栈 注册表中 key为LUA_RIDX_MAINTHREAD的值入栈
    //栈顶的值转换为lua_state  lua_tothread把给定索引处的值转换为一个 Lua 线程 （表示为 lua_State*）。
	lua_State *gL = lua_tothread(L,-1);

	if (forward) {
        //mtask_context.cb设置为forward_cb  mtask_context.cb_ud设置为主线程
		mtask_callback(context, gL, forward_cb);
	} else {
		mtask_callback(context, gL, _cb);
	}

	return 0;
}
//执行一些mtask命令
//使用了简单的文本协议 来 cmd 操作 mtask的服务 例如 LAUNCH NAME QUERY REG KILL SETEVN GETEVN
static int
_command(lua_State *L)
{
	struct mtask_context * context = lua_touserdata(L, lua_upvalueindex(1));
	const char * cmd = luaL_checkstring(L,1);
	const char * result;
	const char * parm = NULL;
	if (lua_gettop(L) == 2) {
		parm = luaL_checkstring(L,2);
	}
    //使用文本命令调用mtask返回一个字符串结果
	result = mtask_command(context, cmd, parm);
	if (result) {
		lua_pushstring(L, result);
		return 1;
	}
	return 0;
}

static int
_intcommand(lua_State *L)
{
	struct mtask_context * context = lua_touserdata(L, lua_upvalueindex(1));
	const char * cmd = luaL_checkstring(L,1);
	const char * result;
	const char * parm = NULL;
	char tmp[64];	// for integer parm
	if (lua_gettop(L) == 2) {
		int32_t n = (int32_t)luaL_checkinteger(L,2);
		sprintf(tmp, "%d", n);
		parm = tmp;
	}

	result = mtask_command(context, cmd, parm);
	if (result) {
		lua_Integer r = strtoll(result, NULL, 0);
		lua_pushinteger(L, r);
		return 1;
	}
	return 0;
}

static int
_genid(lua_State *L)
{
	struct mtask_context * context = lua_touserdata(L, lua_upvalueindex(1));
	int session = mtask_send(context, 0, 0, PTYPE_TAG_ALLOCSESSION , 0 , NULL, 0);//生成一个sesion
	lua_pushinteger(L, session);
	return 1;
}

static const char *
get_dest_string(lua_State *L, int index)
{
	const char * dest_string = lua_tostring(L, index);
	if (dest_string == NULL) {
		luaL_error(L, "dest address type (%s) must be a string or number.", lua_typename(L, lua_type(L,index)));
	}
	return dest_string;
}

/*
	uint32 address
	 string address
	integer type
	integer session
	string message
	 lightuserdata message_ptr
	 integer len
 */
// mtask_context_send mtask_sendname /mtask_send-》mtask_harbor_send | mtask_context_push
static int
_send(lua_State *L)
{
    //如果给定索引处的值是一个完全用户数据,函数返回其内存块的地址.
    //如果值是一个轻量用户数据,那么就返回它表示的指针.
	struct mtask_context * context = lua_touserdata(L, lua_upvalueindex(1));
    //获取目的地址 string 或者 number
    uint32_t dest = (uint32_t)lua_tointeger(L, 1); //目的地址
	const char * dest_string = NULL;
	if (dest == 0) {
		if (lua_type(L,1) == LUA_TNUMBER) {
			return luaL_error(L, "Invalid service address 0");
		}
		dest_string = get_dest_string(L, 1);
	}
    //消息类型
	int type = (int)luaL_checkinteger(L, 2);
    //session
	int session = 0;
	if (lua_isnil(L,3)) {
		type |= PTYPE_TAG_ALLOCSESSION;
	} else {
		session = (int)luaL_checkinteger(L,3);
	}
    //消息数据是字符串或者内存数据 string 和 lightuserdata
	int mtype = lua_type(L,4);
	switch (mtype) {
	case LUA_TSTRING: {//字符串数据
		size_t len = 0;
		void * msg = (void *)lua_tolstring(L,4,&len);
		if (len == 0) {
			msg = NULL;
		}
		if (dest_string) {
			session = mtask_sendname(context, 0, dest_string, type, session , msg, len);
		} else {
			session = mtask_send(context, 0, dest, type, session , msg, len);
		}
		break;
	}
	case LUA_TLIGHTUSERDATA: { //内存数据
		void * msg = lua_touserdata(L,4);
		int size = (int)luaL_checkinteger(L,5);
		if (dest_string) {
			session = mtask_sendname(context, 0, dest_string, type | PTYPE_TAG_DONTCOPY, session, msg, size);
		} else {
			session = mtask_send(context, 0, dest, type | PTYPE_TAG_DONTCOPY, session, msg, size);
		}
		break;
	}
	default:
		luaL_error(L, "mtask.send invalid param %s", lua_typename(L, lua_type(L,4)));
	}
	if (session < 0) {
		// send to invalid address
		// todo: maybe throw an error would be better
		return 0;
	}
	lua_pushinteger(L,session);//seeeion号入栈 也就是返回session
	return 1;//返回值的个数（入栈个数）
}
//和_send 功能类似 但是可以指定一个发送发送地址和消息发送的session
static int
_redirect(lua_State *L)
{
	struct mtask_context * context = lua_touserdata(L, lua_upvalueindex(1));
	uint32_t dest = (uint32_t)lua_tointeger(L,1);//目的地址
	const char * dest_string = NULL;
	if (dest == 0) {
		dest_string = get_dest_string(L, 1);
	}
	uint32_t source = (uint32_t)luaL_checkinteger(L,2);//原地址
	int type = (int)luaL_checkinteger(L,3);//类型
	int session = (int)luaL_checkinteger(L,4);//session

	int mtype = lua_type(L,5);
	switch (mtype) {
	case LUA_TSTRING: {
		size_t len = 0;
		void * msg = (void *)lua_tolstring(L,5,&len);
		if (len == 0) {
			msg = NULL;
		}
		if (dest_string) {
			session = mtask_sendname(context, source, dest_string, type, session , msg, len);
		} else {
			session = mtask_send(context, source, dest, type, session , msg, len);
		}
		break;
	}
	case LUA_TLIGHTUSERDATA: {
		void * msg = lua_touserdata(L,5);
		int size = (int)luaL_checkinteger(L,6); //会多一个 size 参数
		if (dest_string) {
			session = mtask_sendname(context, source, dest_string, type | PTYPE_TAG_DONTCOPY, session, msg, size);
		} else {
			session = mtask_send(context, source, dest, type | PTYPE_TAG_DONTCOPY, session, msg, size);
		}
		break;
	}
	default:
		luaL_error(L, "mtask.redirect invalid param %s", lua_typename(L,mtype));
	}
	return 0;
}

static int
_error(lua_State *L) {
	struct mtask_context * context = lua_touserdata(L, lua_upvalueindex(1));
	mtask_error(context, "%s", luaL_checkstring(L,1));
	return 0;
}

static int
_tostring(lua_State *L) {
	if (lua_isnoneornil(L,1)) {
		return 0;
	}
	char * msg = lua_touserdata(L,1);
	int sz = (int)luaL_checkinteger(L,2);
	lua_pushlstring(L,msg,sz);
	return 1;
}
//C API 用于获得服务所属的节点
static int
_harbor(lua_State *L)
{
	struct mtask_context * context = lua_touserdata(L, lua_upvalueindex(1));
	uint32_t handle = (uint32_t)luaL_checkinteger(L,1);
	int harbor = 0;
	int remote = mtask_isremote(context, handle, &harbor);
	lua_pushinteger(L,harbor);
	lua_pushboolean(L, remote);

	return 2;
}

static int
lpackstring(lua_State *L) {
	_luaseri_pack(L);
	char * str = (char *)lua_touserdata(L, -2);
	int sz = (int)lua_tointeger(L, -1);
	lua_pushlstring(L, str, sz);
	mtask_free(str);
	return 1;
}

static int
ltrash(lua_State *L) {
	int t = lua_type(L,1);
	switch (t) {
	case LUA_TSTRING: {
		break;
	}
	case LUA_TLIGHTUSERDATA: {
		void * msg = lua_touserdata(L,1);
		luaL_checkinteger(L,2);
		mtask_free(msg);
		break;
	}
	default:
		luaL_error(L, "mtask.trash invalid param %s", lua_typename(L,t));
	}

	return 0;
}

static int
lnow(lua_State *L)
{
    uint64_t ti = mtask_now(); //启动时长
    lua_pushinteger(L, ti);
    return 1;
}

int
luaopen_mtask_core(lua_State *L)
{
	luaL_checkversion(L);

	luaL_Reg l[] = {
		{ "send" , _send },
		{ "genid", _genid },
		{ "redirect", _redirect },
		{ "command" , _command },
		{ "intcommand", _intcommand },
		{ "error", _error },
		{ "tostring", _tostring },
		{ "harbor", _harbor },
		{ "pack", _luaseri_pack },
		{ "unpack", _luaseri_unpack },
		{ "packstring", lpackstring },
		{ "trash" , ltrash },
		{ "callback", _callback },
        { "now", lnow }, //节点进程启动时间
		{ NULL, NULL },
	};

	luaL_newlibtable(L, l);

	lua_getfield(L, LUA_REGISTRYINDEX, "mtask_context");
	struct mtask_context *ctx = lua_touserdata(L,-1);
	if (ctx == NULL) {
		return luaL_error(L, "Init mtask context first");
	}

	luaL_setfuncs(L,l,1);

	return 1;
}
