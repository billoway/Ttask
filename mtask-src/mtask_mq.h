#ifndef mtask_MESSAGE_QUEUE_H
#define mtask_MESSAGE_QUEUE_H

#include <stdlib.h>
#include <stdint.h>

//mtask 内部消息结构 sizeof(mtask_message_t) = 24
struct mtask_message_s {
    uint32_t source; //源地址
    int session;     //会话
    void * data;     //数据指针
    size_t sz;       //数据的长度
};

typedef struct mtask_message_s mtask_message_t;

// type is encoding in mtask_message.sz high 8bit
#define MESSAGE_TYPE_MASK (SIZE_MAX >> 8)
#define MESSAGE_TYPE_SHIFT ((sizeof(size_t)-1) * 8)

typedef struct message_queue_s message_queue_t;//消息队列
//压入全局队列
void mtask_globalmq_push(message_queue_t * queue);
//弹出全局队列
message_queue_t * mtask_globalmq_pop(void);
//创建消息队列
message_queue_t * mtask_mq_create(uint32_t handle);
//标记释放消息队列
void mtask_mq_mark_release(message_queue_t *q);

typedef void (*message_drop)(mtask_message_t *, void *);

void mtask_mq_release(message_queue_t *q, message_drop drop_func, void *ud);
//消息队列的句柄
uint32_t mtask_mq_handle(message_queue_t *);

// 0 for success
//消息出队列
int mtask_mq_pop(message_queue_t *q, mtask_message_t *message);
//消息入队列
void mtask_mq_push(message_queue_t *q, mtask_message_t *message);

// return the length of message queue, for debug
//消息队列长度
int mtask_mq_length(message_queue_t *q);

int mtask_mq_overload(message_queue_t *q);
//全局消息队列的初始化
void mtask_mq_init();

#endif
