#ifndef mtask_MONITOR_H
#define mtask_MONITOR_H

#include <stdint.h>

struct mtask_monitor;

struct mtask_monitor * mtask_monitor_new();
void mtask_monitor_delete(struct mtask_monitor *);
void mtask_monitor_trigger(struct mtask_monitor *, uint32_t source, uint32_t destination);
void mtask_monitor_check(struct mtask_monitor *);

#endif
