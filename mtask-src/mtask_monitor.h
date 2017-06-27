#ifndef mtask_MONITOR_H
#define mtask_MONITOR_H

#include <stdint.h>

struct mtask_monitor;// 监视的数据结构
// 新建监视器
struct mtask_monitor * mtask_monitor_new();
// 删除监视器
void mtask_monitor_delete(struct mtask_monitor *);
// 触发监视器
void mtask_monitor_trigger(struct mtask_monitor *, uint32_t source, uint32_t destination);
// 检查监视器
void mtask_monitor_check(struct mtask_monitor *);

#endif
