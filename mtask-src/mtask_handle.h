#ifndef mtask_CONTEXT_HANDLE_H
#define mtask_CONTEXT_HANDLE_H

#include <stdint.h>

// reserve high 8 bits for remote id
#define HANDLE_MASK 0xffffff  //2 ^24 = 16 MB
#define HANDLE_REMOTE_SHIFT 24

struct mtask_context;

uint32_t mtask_handle_register(struct mtask_context *);

int mtask_handle_retire(uint32_t handle);

struct mtask_context * mtask_handle_grab(uint32_t handle);

void mtask_handle_retireall();

uint32_t mtask_handle_findname(const char * name);

const char * mtask_handle_namehandle(uint32_t handle, const char *name);

void mtask_handle_init(int harbor);

#endif
