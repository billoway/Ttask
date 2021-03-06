#include <assert.h>
#include <string.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdio.h>

#include "mtask.h"
#include "mtask_module.h"
#include "mtask_spinlock.h"

// 动态链接库 .so 的加载 和管理模块

#define MAX_MODULE_TYPE 32  //模块类型最大32
//模块管理结构
struct modules {
	int count;              //已加载模块的数量
	spinlock_t lock;   //互斥锁
	const char * path;      //模块路径
	mtask_module_t m[MAX_MODULE_TYPE];//模块数组
};

static struct modules * M = NULL;
//加载so 返回dlopen 返回的句柄
static void *
_try_open(struct modules *m, const char * name)
{
	const char *l;
	const char * path = m->path;
	size_t path_size = strlen(path);
	size_t name_size = strlen(name);

	int sz = (int)(path_size + name_size);
	//search path
	void * dl = NULL;
	char tmp[sz];
	do
	{
		memset(tmp,0,sz);
		while (*path == ';') path++;
		if (*path == '\0') break;//首次出现";"的指针位置
		l = strchr(path, ';');
		if (l == NULL) l = path + strlen(path);
		int len = (int)(l - path);
		int i;
		for (i=0;path[i]!='?' && i < len ;i++) {
			tmp[i] = path[i];
		}
		memcpy(tmp+i,name,name_size);
		if (path[i] == '?') {
			strncpy(tmp+i+name_size,path+i+1,len - i - 1);
		} else {
			fprintf(stderr,"Invalid C service path\n");
			exit(1);
		}
        //加载so库 全局共享解析所有符号的方式加载so
        // dlopen() 打开一个动态链接库，并返回动态链接库的句柄
		dl = dlopen(tmp, RTLD_NOW | RTLD_GLOBAL);
		path = l;
	}while(dl == NULL);

	if (dl == NULL) {
		fprintf(stderr, "try open %s failed : %s\n",name,dlerror());
	}

	return dl;
}
//根据文件名查找动态库的句柄
static mtask_module_t *
_query(const char * name)
{
	int i;
	for (i=0;i<M->count;i++) {
		if (strcmp(M->m[i].name,name)==0) {
			return &M->m[i];
		}
	}
	return NULL;
}

static void *
get_api(mtask_module_t *mod, const char *api_name)
{
    size_t name_size = strlen(mod->name);
    size_t api_size = strlen(api_name);
    char tmp[name_size + api_size + 1];
    memcpy(tmp, mod->name, name_size);
    memcpy(tmp+name_size, api_name, api_size+1);
    char *ptr = strrchr(tmp, '.');
    if (ptr == NULL) {
        ptr = tmp;
    } else {
        ptr = ptr + 1;
    }
    return dlsym(mod->module, ptr);
}

//使用dlsym查找so中的xxx_create xxx_init xxx_release xxx_signal 函数的指针
// dlsym() 根据动态链接库操作句柄与符号，返回符号对应的地址。
static int
_open_sym(mtask_module_t *mod)
{
    mod->create = get_api(mod, "_create");
    mod->init = get_api(mod, "_init");
    mod->release = get_api(mod, "_release");
    mod->signal = get_api(mod, "_signal");

	return mod->init == NULL;
}
mtask_module_t *
mtask_module_query(const char * name)
{
	mtask_module_t * result = _query(name);
	if (result)
		return result;

	SPIN_LOCK(M)

	result = _query(name); // double check
    // 如果没有这个模块 测试打开这个模块
	if (result == NULL && M->count < MAX_MODULE_TYPE) {
		int index = M->count;
		void * dl = _try_open(M,name);// 加载动态链接库 设置模块的函数指针
		if (dl) { //填充mtask_module
			M->m[index].name = name;
			M->m[index].module = dl;

			if (_open_sym(&M->m[index]) == 0) {
				M->m[index].name = mtask_strdup(name);
				M->count ++;
				result = &M->m[index];
			}
		}
	}

	SPIN_UNLOCK(M)

	return result;
}

void 
mtask_module_insert(mtask_module_t *mod)
{
	SPIN_LOCK(M)

	mtask_module_t * m = _query(mod->name);
	assert(m == NULL && M->count < MAX_MODULE_TYPE);
	int index = M->count;
	M->m[index] = *mod;
	++M->count;

	SPIN_UNLOCK(M)
}
void * 
mtask_module_instance_create(mtask_module_t *m)
{
	if (m->create) {
		return m->create();
	} else {
		return (void *)(intptr_t)(~0);
    }
}

int
mtask_module_instance_init(mtask_module_t *m, void * inst,
                           mtask_context_t *ctx, const char * parm)
{
	return m->init(inst, ctx, parm);
}

void 
mtask_module_instance_release(mtask_module_t *m, void *inst)
{
	if (m->release) {
		m->release(inst);
	}
}

void
mtask_module_instance_signal(mtask_module_t *m, void *inst, int signal)
{
	if (m->signal) {
		m->signal(inst, signal);
	}
}
//模块管理的初始化  生成static struct modules * M
void
mtask_module_init(const char *path)
{
	struct modules *m = mtask_malloc(sizeof(*m));
	m->count = 0;
	m->path = mtask_strdup(path);// 初始化模块所在路径 字符串copy

	SPIN_INIT(m)

	M = m;
}
