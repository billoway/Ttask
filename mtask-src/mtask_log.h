#ifndef mtask_log_h
#define mtask_log_h

#include "mtask_env.h"
#include "mtask.h"

#include <stdio.h>
#include <stdint.h>

FILE * mtask_log_open(struct mtask_context * ctx, uint32_t handle);
void mtask_log_close(struct mtask_context * ctx, FILE *f, uint32_t handle);
void mtask_log_output(FILE *f, uint32_t source, int type, int session, void * buffer, size_t sz);

#endif