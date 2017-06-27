#include "mtask.h"

#include "mtask_server.h"
#include "mtask_module.h"
#include "mtask_handle.h"
#include "mtask_mq.h"
#include "mtask_timer.h"
#include "mtask_harbor.h"
#include "mtask_env.h"
#include "mtask_monitor.h"
#include "mtask_imp.h"
#include "mtask_log.h"
#include "mtask_spinlock.h"
#include "mtask_atomic.h"

#include <pthread.h>

#include <string.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdbool.h>


//mtask主要功能，初始化组件、加载服务和通知服务

#ifdef CALLING_CHECK

#define CHECKCALLING_BEGIN(ctx) if (!(spinlock_trylock(&ctx->calling))) { assert(0); }
#define CHECKCALLING_END(ctx) spinlock_unlock(&ctx->calling);
#define CHECKCALLING_INIT(ctx) spinlock_init(&ctx->calling);
#define CHECKCALLING_DESTROY(ctx) spinlock_destroy(&ctx->calling);
#define CHECKCALLING_DECL struct spinlock calling;

#else

#define CHECKCALLING_BEGIN(ctx)
#define CHECKCALLING_END(ctx)
#define CHECKCALLING_INIT(ctx)
#define CHECKCALLING_DESTROY(ctx)
#define CHECKCALLING_DECL

#endif
/*
 * 一个模块(.so)加载到mtask框架中，创建出来的一个实例就是一个服务，
 * 为每个服务分配一个mtask_context结构
 */

//每一个服务对应的 mtask_ctx 结构 mtask上下文结构
struct mtask_context {
	void * instance;          //模块实例化句柄 模块xxx_create函数返回的实例 对应 模块的句柄
	struct mtask_module * mod;//模块结构 保存模块（so）句柄和 函数指针
	void * cb_ud;           //mtask_callback 设置的服务的lua_state
	mtask_cb cb;            //mtask_callback 设置过来的消息处理回调函数
	struct message_queue *queue; //消息队列
	FILE * logfile;
    uint64_t cpu_cost;	// in microsec
    uint64_t cpu_start;	// in microsec
	char result[32];    //保存命令执行返回结果
	uint32_t handle;    //服务的句柄
	int session_id;
	int ref;            //ref引用计数
    int message_count;  //消息数量
	bool init;          //是否实例化
	bool endless;       //是否进入无尽循环
    bool profile;

	CHECKCALLING_DECL
};
//mtask 节点结构
struct mtask_node {
	int total; //节点服务总数
	int init;
	uint32_t monitor_exit;
	pthread_key_t handle_key;//线程局部存储数据 所有线程都可以使用它，而它的值在每一个线程中又是单独存储的
    bool profile;	// default is off

};

static struct mtask_node G_NODE;//节点结构

int 
mtask_context_total()
{
	return G_NODE.total;
}
//原子操作增加节点数量
static void
context_inc()
{
	ATOM_INC(&G_NODE.total);
}
//原子操作减少节点数量
static void
context_dec()
{
	ATOM_DEC(&G_NODE.total);
}

uint32_t 
mtask_current_handle(void) {
	if (G_NODE.init) {
		void * handle = pthread_getspecific(G_NODE.handle_key);
		return (uint32_t)(uintptr_t)handle;
	} else {
		uint32_t v = (uint32_t)(-THREAD_MAIN);
		return v;
	}
}

static void
id_to_hex(char * str, uint32_t id) {
	int i;
	static char hex[16] = { '0','1','2','3','4','5','6','7','8','9','A','B','C','D','E','F' };
	str[0] = ':';
	for (i=0;i<8;i++) {
		str[i+1] = hex[(id >> ((7-i) * 4))&0xf];
	}
	str[9] = '\0';
}

struct drop_t {
	uint32_t handle;
};

static void
drop_message(struct mtask_message *msg, void *ud) {
	struct drop_t *d = ud;
	mtask_free(msg->data);
	uint32_t source = d->handle;
	assert(source);
	// report error to the message source
	mtask_send(NULL, source, msg->source, PTYPE_ERROR, 0, NULL, 0);
}

struct mtask_context * 
mtask_context_new(const char * name, const char *param)
{
    //查询模块数组，找到则直接返回模块结构的指针 没有找到则打开文件进行dlopen加载 同时dlsym找到函数指针 生成mtask_module结构 放入M管理
	struct mtask_module * mod = mtask_module_query(name);

	if (mod == NULL)
		return NULL;
    //调用模块的创建函数 xxx_create() 返回实例句柄
	void *inst = mtask_module_instance_create(mod);
	if (inst == NULL)
		return NULL;
	struct mtask_context * ctx = mtask_malloc(sizeof(*ctx));
	CHECKCALLING_INIT(ctx)
    //填充结构 模块 实例 引用计数
	ctx->mod = mod;
	ctx->instance = inst;
	ctx->ref = 2;
	ctx->cb = NULL;
	ctx->cb_ud = NULL;
	ctx->session_id = 0;
	ctx->logfile = NULL;

	ctx->init = false;
	ctx->endless = false;
    
    ctx->cpu_cost = 0;
    ctx->cpu_start = 0;
    ctx->message_count = 0;
    ctx->profile = G_NODE.profile;
	// Should set to 0 first to avoid mtask_handle_retireall get an uninitialized handle
	ctx->handle = 0;
    //注册ctx,将 ctx 存到 handle_storage (M)哈希表中，并得到一个handle
	ctx->handle = mtask_handle_register(ctx);
    //创建mtask_context中的消息队列 服务句柄会放在消息队列中
	struct message_queue * queue = ctx->queue = mtask_mq_create(ctx->handle);
	// init function maybe use ctx->handle, so it must init at last
	context_inc();
    //模块初始化 xxx_init()
	CHECKCALLING_BEGIN(ctx)
	int r = mtask_module_instance_init(mod, inst, ctx, param);// 实例化 '_init' 函数
	CHECKCALLING_END(ctx)
	if (r == 0) {
		struct mtask_context * ret = mtask_context_release(ctx);//实例化 '_release' 函数 引用计数减少
		if (ret) {
			ctx->init = true;// 实例化 '_init' 成功
		}
		mtask_globalmq_push(queue);// 强行压入消息队列
		if (ret) {
			mtask_error(ret, "LAUNCH %s %s", name, param ? param : "");
		}
		return ret;
	} else {
		mtask_error(ctx, "FAILED launch %s", name);
		uint32_t handle = ctx->handle;
		mtask_context_release(ctx);
		mtask_handle_retire(handle);
		struct drop_t d = { handle };
		mtask_mq_release(queue, drop_message, &d);
		return NULL;
	}
}

int
mtask_context_newsession(struct mtask_context *ctx) {
	// session always be a positive number
	int session = ++ctx->session_id;
	if (session <= 0) {
		ctx->session_id = 1;
		return 1;
	}
	return session;
}

void 
mtask_context_grab(struct mtask_context *ctx) {
	ATOM_INC(&ctx->ref);
}

void
mtask_context_reserve(struct mtask_context *ctx) {
	mtask_context_grab(ctx);
	// don't count the context reserved, because mtask abort (the worker threads terminate) only when the total context is 0 .
	// the reserved context will be release at last.
	context_dec();
}

static void 
delete_context(struct mtask_context *ctx) {
	if (ctx->logfile) {
		fclose(ctx->logfile);
	}
	mtask_module_instance_release(ctx->mod, ctx->instance);
	mtask_mq_mark_release(ctx->queue);
	CHECKCALLING_DESTROY(ctx)
	mtask_free(ctx);
	context_dec();
}
//减少引用计数 引用计数为0删除ctx
struct mtask_context * 
mtask_context_release(struct mtask_context *ctx)
{
	if (ATOM_DEC(&ctx->ref) == 0) {
		delete_context(ctx);
		return NULL;
	}
	return ctx;
}

int
mtask_context_push(uint32_t handle, struct mtask_message *message) {
	struct mtask_context * ctx = mtask_handle_grab(handle);
	if (ctx == NULL) {
		return -1;
	}
	mtask_mq_push(ctx->queue, message);
	mtask_context_release(ctx);

	return 0;
}

void 
mtask_context_endless(uint32_t handle) {
	struct mtask_context * ctx = mtask_handle_grab(handle);
	if (ctx == NULL) {
		return;
	}
	ctx->endless = true;
	mtask_context_release(ctx);
}

int 
mtask_isremote(struct mtask_context * ctx, uint32_t handle, int * harbor) {
	int ret = mtask_harbor_message_isremote(handle);
	if (harbor) {
		*harbor = (int)(handle >> HANDLE_REMOTE_SHIFT);
	}
	return ret;
}

static void
dispatch_message(struct mtask_context *ctx, struct mtask_message *msg) {
	assert(ctx->init);
	CHECKCALLING_BEGIN(ctx)
	pthread_setspecific(G_NODE.handle_key, (void *)(uintptr_t)(ctx->handle));
	int type = msg->sz >> MESSAGE_TYPE_SHIFT;
	size_t sz = msg->sz & MESSAGE_TYPE_MASK;
	if (ctx->logfile) {
		mtask_log_output(ctx->logfile, msg->source, type, msg->session, msg->data, sz);
	}
	if (!ctx->cb(ctx, ctx->cb_ud, type, msg->session, msg->source, msg->data, sz)) {
		mtask_free(msg->data);
	} 
	CHECKCALLING_END(ctx)
}

void 
mtask_context_dispatchall(struct mtask_context * ctx)
{
	// for mtask_error
	struct mtask_message msg;
	struct message_queue *q = ctx->queue;
	while (!mtask_mq_pop(q,&msg)) {
		dispatch_message(ctx, &msg);
	}
}

struct message_queue * 
mtask_context_message_dispatch(struct mtask_monitor *sm, struct message_queue *q, int weight) {
	if (q == NULL) {
		q = mtask_globalmq_pop();
		if (q==NULL)
			return NULL;
	}

	uint32_t handle = mtask_mq_handle(q);

	struct mtask_context * ctx = mtask_handle_grab(handle);
	if (ctx == NULL) {
		struct drop_t d = { handle };
		mtask_mq_release(q, drop_message, &d);
		return mtask_globalmq_pop();
	}

	int i,n=1;
	struct mtask_message msg;

	for (i=0;i<n;i++) {
		if (mtask_mq_pop(q,&msg)) {
			mtask_context_release(ctx);
			return mtask_globalmq_pop();
		} else if (i==0 && weight >= 0) {
			n = mtask_mq_length(q);
			n >>= weight;
		}
		int overload = mtask_mq_overload(q);
		if (overload) {
			mtask_error(ctx, "May overload, message queue length = %d", overload);
		}

		mtask_monitor_trigger(sm, msg.source , handle);

		if (ctx->cb == NULL) {
			mtask_free(msg.data);
		} else {
			dispatch_message(ctx, &msg);
		}

		mtask_monitor_trigger(sm, 0,0);
	}

	assert(q == ctx->queue);
	struct message_queue *nq = mtask_globalmq_pop();
	if (nq) {
		// If global mq is not empty , push q back, and return next queue (nq)
		// Else (global mq is empty or block, don't push q back, and return q again (for next dispatch)
		mtask_globalmq_push(q);
		q = nq;
	} 
	mtask_context_release(ctx);

	return q;
}

static void
copy_name(char name[GLOBALNAME_LENGTH], const char * addr) {
	int i;
	for (i=0;i<GLOBALNAME_LENGTH && addr[i];i++) {
		name[i] = addr[i];
	}
	for (;i<GLOBALNAME_LENGTH;i++) {
		name[i] = '\0';
	}
}

uint32_t 
mtask_queryname(struct mtask_context * context, const char * name) {
	switch(name[0]) {
	case ':':
		return (uint32_t)strtoul(name+1,NULL,16);
	case '.':
		return mtask_handle_findname(name + 1);
	}
	mtask_error(context, "Don't support query global name %s",name);
	return 0;
}

static void
handle_exit(struct mtask_context * context, uint32_t handle) {
	if (handle == 0) {
		handle = context->handle;
		mtask_error(context, "KILL self");
	} else {
		mtask_error(context, "KILL :%0x", handle);
	}
	if (G_NODE.monitor_exit) {
		mtask_send(context,  handle, G_NODE.monitor_exit, PTYPE_CLIENT, 0, NULL, 0);
	}
	mtask_handle_retire(handle);
}

// mtask command

struct command_func {
	const char *name;
	const char * (*func)(struct mtask_context * context, const char * param);
};

static const char *
cmd_timeout(struct mtask_context * context, const char * param) {
	char * session_ptr = NULL;
	int ti = (int)strtol(param, &session_ptr, 10);
	int session = mtask_context_newsession(context);
	mtask_timeout(context->handle, ti, session);
	sprintf(context->result, "%d", session);
	return context->result;
}

static const char *
cmd_reg(struct mtask_context * context, const char * param) {
	if (param == NULL || param[0] == '\0') {
		sprintf(context->result, ":%x", context->handle);
		return context->result;
	} else if (param[0] == '.') {
		return mtask_handle_namehandle(context->handle, param + 1);
	} else {
		mtask_error(context, "Can't register global name %s in C", param);
		return NULL;
	}
}

static const char *
cmd_query(struct mtask_context * context, const char * param)
{
	if (param[0] == '.') {
		uint32_t handle = mtask_handle_findname(param+1);
		if (handle) {
			sprintf(context->result, ":%x", handle);
			return context->result;
		}
	}
	return NULL;
}

static const char *
cmd_name(struct mtask_context * context, const char * param)
{
	int size = (int)strlen(param);
	char name[size+1];
	char handle[size+1];
	sscanf(param,"%s %s",name,handle);
	if (handle[0] != ':') {
		return NULL;
	}
	uint32_t handle_id = (uint32_t)strtoul(handle+1, NULL, 16);
	if (handle_id == 0) {
		return NULL;
	}
	if (name[0] == '.') {
		return mtask_handle_namehandle(handle_id, name + 1);
	} else {
		mtask_error(context, "Can't set global name %s in C", name);
	}
	return NULL;
}


static const char *
cmd_exit(struct mtask_context * context, const char * param) {
	handle_exit(context, 0);
	return NULL;
}

static uint32_t
tohandle(struct mtask_context * context, const char * param) {
	uint32_t handle = 0;
	if (param[0] == ':') {
		handle = (uint32_t)strtoul(param+1, NULL, 16);
	} else if (param[0] == '.') {
		handle = mtask_handle_findname(param+1);
	} else {
		mtask_error(context, "Can't convert %s to handle",param);
	}

	return handle;
}

static const char *
cmd_kill(struct mtask_context * context, const char * param) {
	uint32_t handle = tohandle(context, param);
	if (handle) {
		handle_exit(context, handle);
	}
	return NULL;
}

static const char *
cmd_launch(struct mtask_context * context, const char * param) {
	size_t sz = strlen(param);
	char tmp[sz+1];
	strcpy(tmp,param);
	char * args = tmp;
	char * mod = strsep(&args, " \t\r\n");
	args = strsep(&args, "\r\n");
	struct mtask_context * inst = mtask_context_new(mod,args);
	if (inst == NULL) {
		return NULL;
	} else {
		id_to_hex(context->result, inst->handle);
		return context->result;
	}
}

static const char *
cmd_getenv(struct mtask_context * context, const char * param) {
	return mtask_getenv(param);
}

static const char *
cmd_setenv(struct mtask_context * context, const char * param) {
	size_t sz = strlen(param);
	char key[sz+1];
	int i;
	for (i=0;param[i] != ' ' && param[i];i++) {
		key[i] = param[i];
	}
	if (param[i] == '\0')
		return NULL;

	key[i] = '\0';
	param += i+1;
	
	mtask_setenv(key,param);
	return NULL;
}

static const char *
cmd_starttime(struct mtask_context * context, const char * param) {
	uint32_t sec = mtask_start_time();
	sprintf(context->result,"%u",sec);
	return context->result;
}



static const char *
cmd_abort(struct mtask_context * context, const char * param) {
	mtask_handle_retireall();
	return NULL;
}

static const char *
cmd_monitor(struct mtask_context * context, const char * param)
{
	uint32_t handle=0;
	if (param == NULL || param[0] == '\0') {
		if (G_NODE.monitor_exit) {
			// return current monitor serivce
			sprintf(context->result, ":%x", G_NODE.monitor_exit);
			return context->result;
		}
		return NULL;
	} else {
		handle = tohandle(context, param);
	}
	G_NODE.monitor_exit = handle;
	return NULL;
}

static const char *
cmd_stat(struct mtask_context * context, const char * param)
{
    if (strcmp(param, "mqlen") == 0) {
        int len = mtask_mq_length(context->queue);
        sprintf(context->result, "%d", len);
    } else if (strcmp(param, "endless") == 0) {
        if (context->endless) {
            strcpy(context->result, "1");
            context->endless = false;
        } else {
            strcpy(context->result, "0");
        }
    } else if (strcmp(param, "cpu") == 0) {
        double t = (double)context->cpu_cost / 1000000.0;	// microsec
        sprintf(context->result, "%lf", t);
    } else if (strcmp(param, "time") == 0) {
        if (context->profile) {
            uint64_t ti = mtask_thread_time() - context->cpu_start;
            double t = (double)ti / 1000000.0;	// microsec
            sprintf(context->result, "%lf", t);
        } else {
            strcpy(context->result, "0");
        }
    } else if (strcmp(param, "message") == 0) {
        sprintf(context->result, "%d", context->message_count);
    } else {
        context->result[0] = '\0';
    }
    return context->result;
}


static const char *
cmd_logon(struct mtask_context * context, const char * param) {
	uint32_t handle = tohandle(context, param);
	if (handle == 0)
		return NULL;
	struct mtask_context * ctx = mtask_handle_grab(handle);
	if (ctx == NULL)
		return NULL;
	FILE *f = NULL;
	FILE * lastf = ctx->logfile;
	if (lastf == NULL) {
		f = mtask_log_open(context, handle);
		if (f) {
			if (!ATOM_CAS_POINTER(&ctx->logfile, NULL, f)) {
				// logfile opens in other thread, close this one.
				fclose(f);
			}
		}
	}
	mtask_context_release(ctx);
	return NULL;
}

static const char *
cmd_logoff(struct mtask_context * context, const char * param) {
	uint32_t handle = tohandle(context, param);
	if (handle == 0)
		return NULL;
	struct mtask_context * ctx = mtask_handle_grab(handle);
	if (ctx == NULL)
		return NULL;
	FILE * f = ctx->logfile;
	if (f) {
		// logfile may close in other thread
		if (ATOM_CAS_POINTER(&ctx->logfile, f, NULL)) {
			mtask_log_close(context, f, handle);
		}
	}
	mtask_context_release(ctx);
	return NULL;
}

static const char *
cmd_signal(struct mtask_context * context, const char * param) {
	uint32_t handle = tohandle(context, param);
	if (handle == 0)
		return NULL;
	struct mtask_context * ctx = mtask_handle_grab(handle);
	if (ctx == NULL)
		return NULL;
	param = strchr(param, ' ');
	int sig = 0;
	if (param) {
		sig = (uint32_t)strtol(param, NULL, 0);
	}
	// NOTICE: the signal function should be thread safe.
	mtask_module_instance_signal(ctx->mod, ctx->instance, sig);

	mtask_context_release(ctx);
	return NULL;
}

static struct command_func cmd_funcs[] = {
    { "TIMEOUT", cmd_timeout },
    { "REG", cmd_reg },
    { "QUERY", cmd_query },
    { "NAME", cmd_name },
    { "EXIT", cmd_exit },
    { "KILL", cmd_kill },
    { "LAUNCH", cmd_launch },
    { "GETENV", cmd_getenv },
    { "SETENV", cmd_setenv },
    { "STARTTIME", cmd_starttime },
    { "ABORT", cmd_abort },
    { "MONITOR", cmd_monitor },
    { "STAT", cmd_stat },
    { "LOGON", cmd_logon },
    { "LOGOFF", cmd_logoff },
    { "SIGNAL", cmd_signal },
	{ NULL, NULL },
};

const char * 
mtask_command(struct mtask_context * context, const char * cmd , const char * param) {
	struct command_func * method = &cmd_funcs[0];
	while(method->name) {
		if (strcmp(cmd, method->name) == 0) {
			return method->func(context, param);
		}
		++method;
	}

	return NULL;
}

static void
_filter_args(struct mtask_context * context, int type, int *session, void ** data, size_t * sz) {
	int needcopy = !(type & PTYPE_TAG_DONTCOPY);
	int allocsession = type & PTYPE_TAG_ALLOCSESSION;
	type &= 0xff;

	if (allocsession) {
		assert(*session == 0);
		*session = mtask_context_newsession(context);
	}

	if (needcopy && *data) {
		char * msg = mtask_malloc(*sz+1);
		memcpy(msg, *data, *sz);
		msg[*sz] = '\0';
		*data = msg;
	}

	*sz |= (size_t)type << MESSAGE_TYPE_SHIFT;
}

int
mtask_send(struct mtask_context * context, uint32_t source, uint32_t destination , int type, int session, void * data, size_t sz) {
	if ((sz & MESSAGE_TYPE_MASK) != sz) {
		mtask_error(context, "The message to %x is too large", destination);
		mtask_free(data);
		return -1;
	}
	_filter_args(context, type, &session, (void **)&data, &sz);

	if (source == 0) {
		source = context->handle;
	}

	if (destination == 0) {
		return session;
	}
	if (mtask_harbor_message_isremote(destination)) {
		struct remote_message * rmsg = mtask_malloc(sizeof(*rmsg));
		rmsg->destination.handle = destination;
		rmsg->message = data;
		rmsg->sz = sz;
		mtask_harbor_send(rmsg, source, session);
	} else {
		struct mtask_message smsg;
		smsg.source = source;
		smsg.session = session;
		smsg.data = data;
		smsg.sz = sz;

		if (mtask_context_push(destination, &smsg)) {
			mtask_free(data);
			return -1;
		}
	}
	return session;
}

int
mtask_sendname(struct mtask_context * context, uint32_t source, const char * addr , int type, int session, void * data, size_t sz) {
	if (source == 0) {
		source = context->handle;
	}
	uint32_t des = 0;
	if (addr[0] == ':') {
		des = strtoul(addr+1, NULL, 16);
	} else if (addr[0] == '.') {
		des = mtask_handle_findname(addr + 1);
		if (des == 0) {
			if (type & PTYPE_TAG_DONTCOPY) {
				mtask_free(data);
			}
			return -1;
		}
	} else {
		_filter_args(context, type, &session, (void **)&data, &sz);

		struct remote_message * rmsg = mtask_malloc(sizeof(*rmsg));
		copy_name(rmsg->destination.name, addr);
		rmsg->destination.handle = 0;
		rmsg->message = data;
		rmsg->sz = sz;

		mtask_harbor_send(rmsg, source, session);
		return session;
	}

	return mtask_send(context, source, des, type, session, data, sz);
}

uint32_t 
mtask_context_handle(struct mtask_context *ctx) {
	return ctx->handle;
}

void 
mtask_callback(struct mtask_context * context, void *ud, mtask_cb cb) {
	context->cb = cb;
	context->cb_ud = ud;
}

void
mtask_context_send(struct mtask_context * ctx, void * msg, size_t sz, uint32_t source, int type, int session) {
	struct mtask_message smsg;
	smsg.source = source;
	smsg.session = session;
	smsg.data = msg;
	smsg.sz = sz | (size_t)type << MESSAGE_TYPE_SHIFT;

	mtask_mq_push(ctx->queue, &smsg);
}
//初始化mtask_node 创建线程局部存储key
void 
mtask_globalinit(void)
{
	G_NODE.total = 0;
	G_NODE.monitor_exit = 0;
	G_NODE.init = 1;
	if (pthread_key_create(&G_NODE.handle_key, NULL)) {
		fprintf(stderr, "pthread_key_create failed");
		exit(1);
	}
	// set mainthread's key
	mtask_initthread(THREAD_MAIN);
}

void 
mtask_globalexit(void) {
	pthread_key_delete(G_NODE.handle_key);
}
 //设置线程局部存储key
void
mtask_initthread(int m)
{
	uintptr_t v = (uint32_t)(-m);
	pthread_setspecific(G_NODE.handle_key, (void *)v);
}

