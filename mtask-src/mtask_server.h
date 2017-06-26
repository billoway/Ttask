#ifndef mtask_SERVER_H
#define mtask_SERVER_H

#include <stdint.h>
#include <stdlib.h>
//mtask 主要功能，初始化组件、加载服务和通知服务
struct mtask_context;//每一个服务对应的 mtask_ctx 结构 mtask上下文结构
struct mtask_message;//mtask 内部消息结构
struct mtask_monitor;// 监视的结构

struct mtask_context * mtask_context_new(const char * name, const char * parm);
void mtask_context_grab(struct mtask_context *);
void mtask_context_reserve(struct mtask_context *ctx);
struct mtask_context * mtask_context_release(struct mtask_context *);
uint32_t mtask_context_handle(struct mtask_context *);
int mtask_context_push(uint32_t handle, struct mtask_message *message);
void mtask_context_send(struct mtask_context * context, void * msg, size_t sz, uint32_t source, int type, int session);
int mtask_context_newsession(struct mtask_context *);
struct message_queue * mtask_context_message_dispatch(struct mtask_monitor *, struct message_queue *, int weight);	// return next queue
int mtask_context_total();
void mtask_context_dispatchall(struct mtask_context * context);	// for mtask_error output before exit

void mtask_context_endless(uint32_t handle);	// for monitor

void mtask_globalinit(void);//初始化节点结构mtask_node G_NODE
void mtask_globalexit(void);
void mtask_initthread(int m);

#endif
