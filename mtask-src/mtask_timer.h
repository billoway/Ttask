#ifndef mtask_TIMER_H
#define mtask_TIMER_H

#include <stdint.h>

int mtask_timeout(uint32_t handle, int time, int session);
void mtask_updatetime(void);
uint32_t mtask_gettime(void);
uint32_t mtask_gettime_fixsec(void);

void mtask_timer_init(void);

#endif
