#ifndef mtask_HARBOR_H
#define mtask_HARBOR_H

#include <stdint.h>
#include <stdlib.h>

#define GLOBALNAME_LENGTH 16
#define REMOTE_MAX 256

struct remote_name {
	char name[GLOBALNAME_LENGTH];
	uint32_t handle;
};

struct remote_message {
	struct remote_name destination;
	const void * message;
	size_t sz;
};

void mtask_harbor_send(struct remote_message *rmsg, uint32_t source, int session);
int mtask_harbor_message_isremote(uint32_t handle);
void mtask_harbor_init(int harbor);
void mtask_harbor_start(void * ctx);
void mtask_harbor_exit();

#endif
