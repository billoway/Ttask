#ifndef mtask_MESSAGE_QUEUE_H
#define mtask_MESSAGE_QUEUE_H

#include <stdlib.h>
#include <stdint.h>

struct mtask_message {
	uint32_t source;
	int session;
	void * data;
	size_t sz;
};

// type is encoding in mtask_message.sz high 8bit
#define MESSAGE_TYPE_MASK (SIZE_MAX >> 8)
#define MESSAGE_TYPE_SHIFT ((sizeof(size_t)-1) * 8)

struct message_queue;

void mtask_globalmq_push(struct message_queue * queue);
struct message_queue * mtask_globalmq_pop(void);

struct message_queue * mtask_mq_create(uint32_t handle);
void mtask_mq_mark_release(struct message_queue *q);

typedef void (*message_drop)(struct mtask_message *, void *);

void mtask_mq_release(struct message_queue *q, message_drop drop_func, void *ud);
uint32_t mtask_mq_handle(struct message_queue *);

// 0 for success
int mtask_mq_pop(struct message_queue *q, struct mtask_message *message);
void mtask_mq_push(struct message_queue *q, struct mtask_message *message);

// return the length of message queue, for debug
int mtask_mq_length(struct message_queue *q);
int mtask_mq_overload(struct message_queue *q);

void mtask_mq_init();

#endif
