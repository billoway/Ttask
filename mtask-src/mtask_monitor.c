#include "mtask.h"

#include "mtask_monitor.h"
#include "mtask_server.h"
#include "mtask.h"
#include "mtask_atomic.h"

#include <stdlib.h>
#include <string.h>

struct mtask_monitor {
	int version;
	int check_version;
	uint32_t source;
	uint32_t destination;
};

struct mtask_monitor * 
mtask_monitor_new() {
	struct mtask_monitor * ret = mtask_malloc(sizeof(*ret));
	memset(ret, 0, sizeof(*ret));
	return ret;
}

void 
mtask_monitor_delete(struct mtask_monitor *sm) {
	mtask_free(sm);
}

void 
mtask_monitor_trigger(struct mtask_monitor *sm, uint32_t source, uint32_t destination) {
	sm->source = source;
	sm->destination = destination;
	ATOM_INC(&sm->version);
}

void 
mtask_monitor_check(struct mtask_monitor *sm) {
	if (sm->version == sm->check_version) {
		if (sm->destination) {
			mtask_context_endless(sm->destination);
			mtask_error(NULL, "A message from [ :%08x ] to [ :%08x ] maybe in an endless loop (version = %d)", sm->source , sm->destination, sm->version);
		}
	} else {
		sm->check_version = sm->version;
	}
}
