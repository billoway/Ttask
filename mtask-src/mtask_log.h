#ifndef mtask_log_h
#define mtask_log_h

#include <stdio.h>
#include <stdint.h>

#include "mtask_env.h"

FILE * mtask_log_open(mtask_context_t * ctx, uint32_t handle);

void mtask_log_close(mtask_context_t * ctx, FILE *f, uint32_t handle);

void mtask_log_output(FILE *f, uint32_t source, int type, int session, void * buffer, size_t sz);

#endif
