#ifndef mtask_MODULE_H
#define mtask_MODULE_H


//声明dl中的函数指针
typedef void * (*mtask_dl_create)(void);
typedef int (*mtask_dl_init)(void * inst, mtask_context_t *, const char * parm);
typedef void (*mtask_dl_release)(void * inst);
typedef void (*mtask_dl_signal)(void * inst, int signal);

//声明模块结构
struct mtask_module_s {
    const char * name;     //模块名称
    void * module;         //用于保存dlopen返回的handle
    mtask_dl_create create; //用于保存xxx_create函数入口地址  地址是mtask_module_query()中加载模块的时候通过dlsym找到的函数指针
    mtask_dl_init init;     //用于保存xxx_init函数入口地址
    mtask_dl_release release; //用于保存xxx_release函数入口地址
    mtask_dl_signal signal;   //用于保存xxx_signal函数入口地址
};

typedef struct mtask_module_s mtask_module_t;

void mtask_module_insert(mtask_module_t *mod);

mtask_module_t * mtask_module_query(const char * name);

void * mtask_module_instance_create(mtask_module_t *);

int mtask_module_instance_init(mtask_module_t *, void * inst, mtask_context_t *ctx, const char * parm);

void mtask_module_instance_release(mtask_module_t *, void *inst);

void mtask_module_instance_signal(mtask_module_t *, void *inst, int signal);

void mtask_module_init(const char *path);

#endif
