#include "mtask.h"

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

struct logger {
	FILE * handle;
	int close;
};

struct logger *
logger_create(void) {
	struct logger * inst = mtask_malloc(sizeof(*inst));
	inst->handle = NULL;
	inst->close = 0;
	return inst;
}

void
logger_release(struct logger * inst) {
	if (inst->close) {
		fclose(inst->handle);
	}
	mtask_free(inst);
}

static int
_logger(struct mtask_context * context, void *ud, int type, int session, uint32_t source, const void * msg, size_t sz) {
	struct logger * inst = ud;
	fprintf(inst->handle, "[:%08x] ",source);
	fwrite(msg, sz , 1, inst->handle);
	fprintf(inst->handle, "\n");
	fflush(inst->handle);

	return 0;
}

int
logger_init(struct logger * inst, struct mtask_context *ctx, const char * parm) {
	if (parm) {
		inst->handle = fopen(parm,"w");
		if (inst->handle == NULL) {
			return 1;
		}
		inst->close = 1;
	} else {
		inst->handle = stdout;
	}
	if (inst->handle) {
		mtask_callback(ctx, inst, _logger);
		mtask_command(ctx, "REG", ".logger");
		return 0;
	}
	return 1;
}
