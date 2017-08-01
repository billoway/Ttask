#ifndef mtask_MONITOR_H
#define mtask_MONITOR_H

#include <stdint.h>
// 监视的数据结构
typedef struct mtask_monitor_s mtask_monitor_t;
// 新建监视器
mtask_monitor_t * mtask_monitor_new();
// 删除监视器
void mtask_monitor_delete(mtask_monitor_t *);
// 触发监视器
void mtask_monitor_trigger(mtask_monitor_t *, uint32_t source, uint32_t destination);
// 检查监视器
void mtask_monitor_check(mtask_monitor_t *);

#endif
