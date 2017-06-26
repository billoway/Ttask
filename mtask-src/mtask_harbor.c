#include "mtask.h"
#include "mtask_harbor.h"
#include "mtask_server.h"
#include "mtask_mq.h"
#include "mtask_handle.h"

#include <string.h>
#include <stdio.h>
#include <assert.h>

static struct mtask_context * REMOTE = 0;
static unsigned int HARBOR = ~0;

void 
mtask_harbor_send(struct remote_message *rmsg, uint32_t source, int session) {
	int type = rmsg->sz >> MESSAGE_TYPE_SHIFT;
	rmsg->sz &= MESSAGE_TYPE_MASK;
	assert(type != PTYPE_SYSTEM && type != PTYPE_HARBOR && REMOTE);
	mtask_context_send(REMOTE, rmsg, sizeof(*rmsg) , source, type , session);
}

int 
mtask_harbor_message_isremote(uint32_t handle) {
	assert(HARBOR != ~0);
	int h = (handle & ~HANDLE_MASK);
	return h != HARBOR && h !=0;
}

void
mtask_harbor_init(int harbor)
{
    // 高8位就是对应远程主机通信的 harbor
	HARBOR = (unsigned int)harbor << HANDLE_REMOTE_SHIFT;
}

void
mtask_harbor_start(void *ctx) {
	// the HARBOR must be reserved to ensure the pointer is valid.
	// It will be released at last by calling mtask_harbor_exit
	mtask_context_reserve(ctx);
	REMOTE = ctx;
}

void
mtask_harbor_exit() {
	struct mtask_context * ctx = REMOTE;
	REMOTE= NULL;
	if (ctx) {
		mtask_context_release(ctx);
	}
}
