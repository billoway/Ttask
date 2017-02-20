#ifndef mtask_MODULE_H
#define mtask_MODULE_H

struct mtask_context;

typedef void * (*mtask_dl_create)(void);
typedef int (*mtask_dl_init)(void * inst, struct mtask_context *, const char * parm);
typedef void (*mtask_dl_release)(void * inst);
typedef void (*mtask_dl_signal)(void * inst, int signal);

struct mtask_module {
	const char * name;
	void * module;
	mtask_dl_create create;
	mtask_dl_init init;
	mtask_dl_release release;
	mtask_dl_signal signal;
};

void mtask_module_insert(struct mtask_module *mod);
struct mtask_module * mtask_module_query(const char * name);
void * mtask_module_instance_create(struct mtask_module *);
int mtask_module_instance_init(struct mtask_module *, void * inst, struct mtask_context *ctx, const char * parm);
void mtask_module_instance_release(struct mtask_module *, void *inst);
void mtask_module_instance_signal(struct mtask_module *, void *inst, int signal);

void mtask_module_init(const char *path);

#endif
