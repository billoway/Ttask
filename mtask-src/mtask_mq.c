
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <stdbool.h>

#include "mtask.h"
#include "mtask_mq.h"
#include "mtask_handle.h"
#include "mtask_spinlock.h"

#define DEFAULT_QUEUE_SIZE 64       //默认队列大小
#define MAX_GLOBAL_MQ 0x10000       //最大的全局消息队列的大小 64K

// 0 means mq is not in global mq.
// 1 means mq is in global mq , or the message is dispatching.

#define MQ_IN_GLOBAL 1      //在全局队列中或者正在分发
#define MQ_OVERLOAD 1024


//消息队列结构 sizeof(message_queue_t) = 56
struct message_queue_s {
    spinlock_t lock;//自旋锁
    uint32_t handle;  //服务的地址(句柄)
    int cap;          //队列大小(此结构的消息容量)
    int head;         //队列头(索引头)
    int tail;         //队列尾
    int release;      //释放标志(如果此标志被置为1，此结构体会被释放)
    int in_global;    //是否在全局消息队列中的flag
    int overload;     //如果过载，非0(置为消息队列当前的消息长度)
    int overload_threshold;//过载阀值，超过此值说明过载了
    mtask_message_t *queue; //存放具体消息的连续内存的指针(服务的一条消息对应一个mtask_message_t结构)
    message_queue_t *next;  //下一个服务的消息队列节点指针
};

//全局消息队列链表 其中保存了非空的各个服务的消息队列message_queue
struct global_queue_s {
    message_queue_t *head;
    message_queue_t *tail;
    spinlock_t lock;
};

typedef struct global_queue_s global_queue_t;
//全局队列的指针变量
static global_queue_t *Q = NULL;
//消息队列挂在全局消息队列(链表)的尾部
void
mtask_globalmq_push(message_queue_t * queue)
{
	global_queue_t *q = Q;

	SPIN_LOCK(q)
	assert(queue->next == NULL);
	if(q->tail) {
		q->tail->next = queue;
		q->tail = queue;
	} else { // 如果为空队列
		q->head = q->tail = queue;
	}
	SPIN_UNLOCK(q)
}
//取出全局消息队列链表头部的消息队列
message_queue_t *
mtask_globalmq_pop()
{
	global_queue_t *q = Q;

	SPIN_LOCK(q)
	message_queue_t *mq = q->head;
	if(mq) {
		q->head = mq->next;
		if(q->head == NULL) {
			assert(mq == q->tail);
			q->tail = NULL;
		}
		mq->next = NULL;
	}
	SPIN_UNLOCK(q)

	return mq;
}
//创建消息队列
message_queue_t * 
mtask_mq_create(uint32_t handle)
{
	message_queue_t *q = mtask_malloc(sizeof(*q)); //创建消息队列
	q->handle = handle; //记录handle
	q->cap = DEFAULT_QUEUE_SIZE;
	q->head = 0;
	q->tail = 0;
	SPIN_INIT(q)
	// When the queue is create (always between service create and service init) ,
	// set in_global flag to avoid push it to global queue .
	// If the service init success, mtask_context_new will call mtask_mq_force_push to push it to global queue.
	q->in_global = MQ_IN_GLOBAL;//在全局队列中
	q->release = 0;
	q->overload = 0;
	q->overload_threshold = MQ_OVERLOAD;
	q->queue = mtask_malloc(sizeof(mtask_message_t) * q->cap);//分配连续的cap内存用于存放具体消息
	q->next = NULL;

	return q;
}

static void 
_release(message_queue_t *q)
{
	assert(q->next == NULL);
	SPIN_DESTROY(q)
	mtask_free(q->queue);
	mtask_free(q);
}

uint32_t 
mtask_mq_handle(message_queue_t *q)
{
	return q->handle;
}
//消息队列的长度
int
mtask_mq_length(message_queue_t *q)
{
	int head, tail,cap;

	SPIN_LOCK(q)
	head = q->head;
	tail = q->tail;
	cap = q->cap;
	SPIN_UNLOCK(q)
	
	if (head <= tail) {
		return tail - head;
	}
	return tail + cap - head;
}

int
mtask_mq_overload(message_queue_t *q)
{
	if (q->overload) {
		int overload = q->overload;
		q->overload = 0;
		return overload;
	} 
	return 0;
}
//弹出消息队列中的头部消息
int
mtask_mq_pop(message_queue_t *q, mtask_message_t *message)
{
	int ret = 1;
	SPIN_LOCK(q)

	if (q->head != q->tail) {           //如果队列头不等于队列尾
		*message = q->queue[q->head++]; //取出队列头
		ret = 0;                        //弹出成功返回0
		int head = q->head;
		int tail = q->tail;
		int cap = q->cap;

		if (head >= cap) {              //如果队列头 >= 最大队列数
			q->head = head = 0;
		}
		int length = tail - head;
		if (length < 0) {
			length += cap;
		}
        //如果过载，将目前消息队列的长度复制，并将过载阀值扩充一倍
		while (length > q->overload_threshold) {
			q->overload = length;
			q->overload_threshold *= 2;
		}
	} else {
		// reset overload_threshold when queue is empty
		q->overload_threshold = MQ_OVERLOAD;
	}

	if (ret) {
		q->in_global = 0;           //设置在全局状态为0
	}
	
	SPIN_UNLOCK(q)

	return ret;
}
//扩展消息队列message_queue 中的存放消息的内存空间
static void
expand_queue(message_queue_t *q)
{
	mtask_message_t *new_queue = mtask_malloc(sizeof(mtask_message_t) * q->cap * 2);
	int i;
	for (i=0;i<q->cap;i++) {
		new_queue[i] = q->queue[(q->head + i) % q->cap];
	}
	q->head = 0;
	q->tail = q->cap;
	q->cap *= 2;
	
	mtask_free(q->queue);
	q->queue = new_queue;
}
//将服务的某条消息压入服务的消息队列尾
//如果标识为在全局中 则将消息队列挂在到全局消息队列的尾部
void
mtask_mq_push(message_queue_t *q, mtask_message_t *message)
{
	assert(message);
	SPIN_LOCK(q)

	q->queue[q->tail] = *message;//将消息压入消息队列的尾
	if (++ q->tail >= q->cap) {
		q->tail = 0;
	}

	if (q->head == q->tail) {//如果队列头等于队列尾 扩容
		expand_queue(q);
	}

	if (q->in_global == 0) { //如果在全局标志等于0  设置标志为在全局 压入全局消息队列
		q->in_global = MQ_IN_GLOBAL;
		mtask_globalmq_push(q);
	}
	
	SPIN_UNLOCK(q)
}
//初始化全局消息队列 分配和初始struct global_queue内存结构
void
mtask_mq_init()
{
	global_queue_t *q = mtask_malloc(sizeof(*q));
	memset(q,0,sizeof(*q));
	SPIN_INIT(q);
	Q = q;
}
//标记消息队列release = 1 并且将消息队列放入全局消息队列链表
void
mtask_mq_mark_release(message_queue_t *q)
{
	SPIN_LOCK(q)
	assert(q->release == 0);
	q->release = 1;
	if (q->in_global != MQ_IN_GLOBAL) {
		mtask_globalmq_push(q);
	}
	SPIN_UNLOCK(q)
}
//消息弹出消息队列 删除消息队列中的消息内存块数据
static void
_drop_queue(message_queue_t *q, message_drop drop_func, void *ud)
{
	mtask_message_t msg;
	while(!mtask_mq_pop(q, &msg)) {
		drop_func(&msg, ud);
	}
	_release(q);
}
//释放消息队列  消息弹出消息队列 删除消息队列中的消息内存块数据
void
mtask_mq_release(message_queue_t *q, message_drop drop_func, void *ud)
{
	SPIN_LOCK(q)
	
	if (q->release) {
		SPIN_UNLOCK(q)
		_drop_queue(q, drop_func, ud);
	} else {
		mtask_globalmq_push(q);
		SPIN_UNLOCK(q)
	}
}
