#include <stdlib.h>
#include <string.h>

#include "mtask.h"
#include "mtask_monitor.h"
#include "mtask_server.h"
#include "mtask_atomic.h"

// 监视的结构
struct mtask_monitor_s {
    int version;        // 版本
    int check_version;  // 检查版本
    uint32_t source;    // 来源
    uint32_t destination; // 目的
};

mtask_monitor_t * 
mtask_monitor_new()
{
	mtask_monitor_t * ret = mtask_malloc(sizeof(*ret));
	memset(ret, 0, sizeof(*ret));
	return ret;
}

void 
mtask_monitor_delete(mtask_monitor_t *sm)
{
	mtask_free(sm);
}

void 
mtask_monitor_trigger(mtask_monitor_t *sm, uint32_t source, uint32_t destination)
{
	sm->source = source;            // 来源
	sm->destination = destination;  // 目的
	ATOM_INC(&sm->version);         // 版本 +1
}

void 
mtask_monitor_check(mtask_monitor_t *sm)
{
    // 如果版本等于检查版本 mtask_monitor_trigger时设置了version加1 如果相等则进入了无限循环
	if (sm->version == sm->check_version) {
		if (sm->destination) {// 目的是否存在
			mtask_context_endless(sm->destination);
			mtask_error(NULL, "A message from [ :%08x ] to [ :%08x ] maybe in an endless loop (version = %d)", sm->source , sm->destination, sm->version);
		}
	} else {// 否则检查版本等于版本
		sm->check_version = sm->version;
	}
}
