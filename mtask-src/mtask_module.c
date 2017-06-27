#include "mtask.h"

#include "mtask_module.h"
#include "mtask_spinlock.h"

#include <assert.h>
#include <string.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdio.h>

#define MAX_MODULE_TYPE 32

struct modules {
	int count;
	struct spinlock lock;
	const char * path;
	struct mtask_module m[MAX_MODULE_TYPE];
};

static struct modules * M = NULL;
//加载so 返回dlopen 返回的句柄
static void *
_try_open(struct modules *m, const char * name) {
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
		if (*path == '\0') break;
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
		dl = dlopen(tmp, RTLD_NOW | RTLD_GLOBAL);// dlopen() 打开一个动态链接库，并返回动态链接库的句柄
		path = l;
	}while(dl == NULL);

	if (dl == NULL) {
		fprintf(stderr, "try open %s failed : %s\n",name,dlerror());
	}

	return dl;
}
//根据文件名查找动态库的句柄
static struct mtask_module *
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

static int
_open_sym(struct mtask_module *mod) {
	size_t name_size = strlen(mod->name);
	char tmp[name_size + 9]; // create/init/release/signal , longest name is release (7)
	memcpy(tmp, mod->name, name_size);
	strcpy(tmp+name_size, "_create");
	mod->create = dlsym(mod->module, tmp);
	strcpy(tmp+name_size, "_init");
	mod->init = dlsym(mod->module, tmp);
	strcpy(tmp+name_size, "_release");
	mod->release = dlsym(mod->module, tmp);
	strcpy(tmp+name_size, "_signal");
	mod->signal = dlsym(mod->module, tmp);

	return mod->init == NULL;
}
//根据模块名找模块 mtask_module* 结构，如果不存在则加载so
struct mtask_module *
mtask_module_query(const char * name)
{
	struct mtask_module * result = _query(name);
	if (result)
		return result;

	SPIN_LOCK(M)

	result = _query(name); // double check

	if (result == NULL && M->count < MAX_MODULE_TYPE) {
		int index = M->count;
		void * dl = _try_open(M,name);
		if (dl) {
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
mtask_module_insert(struct mtask_module *mod) {
	SPIN_LOCK(M)

	struct mtask_module * m = _query(mod->name);
	assert(m == NULL && M->count < MAX_MODULE_TYPE);
	int index = M->count;
	M->m[index] = *mod;
	++M->count;

	SPIN_UNLOCK(M)
}
// intptr_t对于32位环境是int，对于64位环境是long int
// C99规定intptr_t可以保存指针值，因而将(~0)先转为intptr_t再转为void*
void * 
mtask_module_instance_create(struct mtask_module *m)
{
	if (m->create) {
		return m->create();
	} else {
		return (void *)(intptr_t)(~0);
    }
}

int
mtask_module_instance_init(struct mtask_module *m, void * inst, struct mtask_context *ctx, const char * parm)
{
	return m->init(inst, ctx, parm);
}

void 
mtask_module_instance_release(struct mtask_module *m, void *inst) {
	if (m->release) {
		m->release(inst);
	}
}

void
mtask_module_instance_signal(struct mtask_module *m, void *inst, int signal) {
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
