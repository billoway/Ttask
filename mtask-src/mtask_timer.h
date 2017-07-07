#ifndef mtask_TIMER_H
#define mtask_TIMER_H

//mtask 的内部时钟精度为 1/100 秒
#include <stdint.h>

int mtask_timeout(uint32_t handle, int time, int session);

void mtask_updatetime(void);

uint32_t mtask_starttime(void);
// for profile, in micro second
uint64_t mtask_thread_time(void);

void mtask_timer_init(void);

#endif
