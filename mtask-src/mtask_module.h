#ifndef mtask_MODULE_H
#define mtask_MODULE_H

struct mtask_context;
//声明dl中的函数指针
typedef void * (*mtask_dl_create)(void);
typedef int (*mtask_dl_init)(void * inst, struct mtask_context *, const char * parm);
typedef void (*mtask_dl_release)(void * inst);
typedef void (*mtask_dl_signal)(void * inst, int signal);

//声明模块结构
struct mtask_module {
    const char * name;     //模块名称
    void * module;         //用于保存dlopen返回的handle
    mtask_dl_create create; //用于保存xxx_create函数入口地址  地址是mtask_module_query()中加载模块的时候通过dlsym找到的函数指针
    mtask_dl_init init;     //用于保存xxx_init函数入口地址
    mtask_dl_release release; //用于保存xxx_release函数入口地址
    mtask_dl_signal signal;   //用于保存xxx_signal函数入口地址
};

void mtask_module_insert(struct mtask_module *mod);

struct mtask_module * mtask_module_query(const char * name);

void * mtask_module_instance_create(struct mtask_module *);

int mtask_module_instance_init(struct mtask_module *, void * inst, struct mtask_context *ctx, const char * parm);

void mtask_module_instance_release(struct mtask_module *, void *inst);

void mtask_module_instance_signal(struct mtask_module *, void *inst, int signal);

void mtask_module_init(const char *path);

#endif
