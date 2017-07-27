#ifndef mtask_TIMER_H
#define mtask_TIMER_H

//mtask 的内部时钟精度为 1/100 秒
#include <stdint.h>

int mtask_timeout(uint32_t handle, int time, int session);

void mtask_time_update(void);

uint32_t mtask_time_start(void);
// for profile, in micro second
uint64_t mtask_time_thread(void);

void mtask_timer_init(void);

#endif
