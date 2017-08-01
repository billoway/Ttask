#ifndef mtask_SERVER_H
#define mtask_SERVER_H

#include <stdint.h>
#include <stdlib.h>
#include "mtask.h"
#include "mtask_monitor.h"
//mtask 主要功能，初始化组件、加载服务和通知服务
struct mtask_message;//mtask 内部消息结构

mtask_context_t * mtask_context_new(const char * name, const char * parm);

void mtask_context_grab(mtask_context_t *);

void mtask_context_reserve(mtask_context_t *ctx);

mtask_context_t * mtask_context_release(mtask_context_t *);

uint32_t mtask_context_handle(mtask_context_t *);

int mtask_context_push(uint32_t handle, struct mtask_message *message);

void mtask_context_send(mtask_context_t * context, void * msg, size_t sz, uint32_t source, int type, int session);

int mtask_context_newsession(mtask_context_t *);
// return next queue
struct message_queue * mtask_context_message_dispatch(mtask_monitor_t *, struct message_queue *, int weight);

int mtask_context_total();
// for mtask_error output before exit
void mtask_context_dispatchall(mtask_context_t * context);
// for monitor
void mtask_context_endless(uint32_t handle);
//初始化节点结构mtask_node G_NODE
void mtask_global_init(void);

void mtask_global_exit(void);

void mtask_thread_init(int m);

void mtask_profile_enable(int enable);

#endif
