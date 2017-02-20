#ifndef mtask_H
#define mtask_H

#include "mtask_malloc.h"

#include <stddef.h>
#include <stdint.h>

#define PTYPE_TEXT 0
#define PTYPE_RESPONSE 1
#define PTYPE_MULTICAST 2
#define PTYPE_CLIENT 3
#define PTYPE_SYSTEM 4
#define PTYPE_HARBOR 5
#define PTYPE_SOCKET 6
// read lualib/mtask.lua examples/simplemonitor.lua
#define PTYPE_ERROR 7
// read lualib/mtask.lua lualib/mqueue.lua lualib/snax.lua
#define PTYPE_RESERVED_QUEUE 8
#define PTYPE_RESERVED_DEBUG 9
#define PTYPE_RESERVED_LUA 10
#define PTYPE_RESERVED_SNAX 11

#define PTYPE_TAG_DONTCOPY 0x10000
#define PTYPE_TAG_ALLOCSESSION 0x20000

struct mtask_context;

void mtask_error(struct mtask_context * context, const char *msg, ...);
const char * mtask_command(struct mtask_context * context, const char * cmd , const char * parm);
uint32_t mtask_queryname(struct mtask_context * context, const char * name);
int mtask_send(struct mtask_context * context, uint32_t source, uint32_t destination , int type, int session, void * msg, size_t sz);
int mtask_sendname(struct mtask_context * context, uint32_t source, const char * destination , int type, int session, void * msg, size_t sz);

int mtask_isremote(struct mtask_context *, uint32_t handle, int * harbor);

typedef int (*mtask_cb)(struct mtask_context * context, void *ud, int type, int session, uint32_t source , const void * msg, size_t sz);
void mtask_callback(struct mtask_context * context, void *ud, mtask_cb cb);

uint32_t mtask_current_handle(void);

#endif
