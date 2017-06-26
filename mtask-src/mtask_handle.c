#include "mtask.h"

#include "mtask_handle.h"
#include "mtask_server.h"
#include "rwlock.h"

#include <stdlib.h>
#include <assert.h>
#include <string.h>

// mtask 服务编号的管理和分配

#define DEFAULT_SLOT_SIZE 4
#define MAX_SLOT_SIZE 0x40000000
//服务名字和服务编号的对应结构
struct handle_name {
	char * name;
	uint32_t handle;
};
// 存储handle与mtask_context的对应关系，是一个哈希表
// 每个服务mtask_context都对应一个不重复的handle
// 存储name和handle的对应关系
// 通过handle便可获取mtask_context
struct handle_storage {
	struct rwlock lock; //读写锁

	uint32_t harbor;    //服务所属harbor  harbor用于不同主机间通信
	uint32_t handle_index;//初始值为1，表示handle句柄起始值从1开始
	int slot_size;       //hash 表空间大小，初始为DEFAULT_SLOT_SIZE
	struct mtask_context ** slot;//mtask_context 表空间
	
	int name_cap;   //handle_name容量，初始为2，这里 name_cap 与 slot_size 不一样的原因在于，不是每个 handle 都有name
	int name_count;  //handle_name数量
	struct handle_name *name;//handle_name表
};

static struct handle_storage *H = NULL;

uint32_t
mtask_handle_register(struct mtask_context *ctx) {
	struct handle_storage *s = H;

	rwlock_wlock(&s->lock);
	
	for (;;) {
		int i;
		for (i=0;i<s->slot_size;i++) {
			uint32_t handle = (i+s->handle_index) & HANDLE_MASK;
			int hash = handle & (s->slot_size-1);
			if (s->slot[hash] == NULL) {
				s->slot[hash] = ctx;
				s->handle_index = handle + 1;

				rwlock_wunlock(&s->lock);

				handle |= s->harbor;
				return handle;
			}
		}
		assert((s->slot_size*2 - 1) <= HANDLE_MASK);
		struct mtask_context ** new_slot = mtask_malloc(s->slot_size * 2 * sizeof(struct mtask_context *));
		memset(new_slot, 0, s->slot_size * 2 * sizeof(struct mtask_context *));
		for (i=0;i<s->slot_size;i++) {
			int hash = mtask_context_handle(s->slot[i]) & (s->slot_size * 2 - 1);
			assert(new_slot[hash] == NULL);
			new_slot[hash] = s->slot[i];
		}
		mtask_free(s->slot);
		s->slot = new_slot;
		s->slot_size *= 2;
	}
}

int
mtask_handle_retire(uint32_t handle) {
	int ret = 0;
	struct handle_storage *s = H;

	rwlock_wlock(&s->lock);

	uint32_t hash = handle & (s->slot_size-1);
	struct mtask_context * ctx = s->slot[hash];

	if (ctx != NULL && mtask_context_handle(ctx) == handle) {
		s->slot[hash] = NULL;
		ret = 1;
		int i;
		int j=0, n=s->name_count;
		for (i=0; i<n; ++i) {
			if (s->name[i].handle == handle) {
				mtask_free(s->name[i].name);
				continue;
			} else if (i!=j) {
				s->name[j] = s->name[i];
			}
			++j;
		}
		s->name_count = j;
	} else {
		ctx = NULL;
	}

	rwlock_wunlock(&s->lock);

	if (ctx) {
		// release ctx may call mtask_handle_* , so wunlock first.
		mtask_context_release(ctx);
	}

	return ret;
}

void 
mtask_handle_retireall() {
	struct handle_storage *s = H;
	for (;;) {
		int n=0;
		int i;
		for (i=0;i<s->slot_size;i++) {
			rwlock_rlock(&s->lock);
			struct mtask_context * ctx = s->slot[i];
			uint32_t handle = 0;
			if (ctx)
				handle = mtask_context_handle(ctx);
			rwlock_runlock(&s->lock);
			if (handle != 0) {
				if (mtask_handle_retire(handle)) {
					++n;
				}
			}
		}
		if (n==0)
			return;
	}
}

struct mtask_context * 
mtask_handle_grab(uint32_t handle) {
	struct handle_storage *s = H;
	struct mtask_context * result = NULL;

	rwlock_rlock(&s->lock);

	uint32_t hash = handle & (s->slot_size-1);
	struct mtask_context * ctx = s->slot[hash];
	if (ctx && mtask_context_handle(ctx) == handle) {
		result = ctx;
		mtask_context_grab(result);
	}

	rwlock_runlock(&s->lock);

	return result;
}

uint32_t 
mtask_handle_findname(const char * name) {
	struct handle_storage *s = H;

	rwlock_rlock(&s->lock);

	uint32_t handle = 0;

	int begin = 0;
	int end = s->name_count - 1;
	while (begin<=end) {
		int mid = (begin+end)/2;
		struct handle_name *n = &s->name[mid];
		int c = strcmp(n->name, name);
		if (c==0) {
			handle = n->handle;
			break;
		}
		if (c<0) {
			begin = mid + 1;
		} else {
			end = mid - 1;
		}
	}

	rwlock_runlock(&s->lock);

	return handle;
}

static void
_insert_name_before(struct handle_storage *s, char *name, uint32_t handle, int before) {
	if (s->name_count >= s->name_cap) {
		s->name_cap *= 2;
		assert(s->name_cap <= MAX_SLOT_SIZE);
		struct handle_name * n = mtask_malloc(s->name_cap * sizeof(struct handle_name));
		int i;
		for (i=0;i<before;i++) {
			n[i] = s->name[i];
		}
		for (i=before;i<s->name_count;i++) {
			n[i+1] = s->name[i];
		}
		mtask_free(s->name);
		s->name = n;
	} else {
		int i;
		for (i=s->name_count;i>before;i--) {
			s->name[i] = s->name[i-1];
		}
	}
	s->name[before].name = name;
	s->name[before].handle = handle;
	s->name_count ++;
}

static const char *
_insert_name(struct handle_storage *s, const char * name, uint32_t handle) {
	int begin = 0;
	int end = s->name_count - 1;
	while (begin<=end) {
		int mid = (begin+end)/2;
		struct handle_name *n = &s->name[mid];
		int c = strcmp(n->name, name);
		if (c==0) {
			return NULL;
		}
		if (c<0) {
			begin = mid + 1;
		} else {
			end = mid - 1;
		}
	}
	char * result = mtask_strdup(name);

	_insert_name_before(s, result, handle, begin);

	return result;
}

const char * 
mtask_handle_namehandle(uint32_t handle, const char *name) {
	rwlock_wlock(&H->lock);

	const char * ret = _insert_name(H, name, handle);

	rwlock_wunlock(&H->lock);

	return ret;
}
// 初始化一个 handle 就是初始化 handle_storage
void
mtask_handle_init(int harbor)
{
	assert(H==NULL);
	struct handle_storage * s = mtask_malloc(sizeof(*H));
	s->slot_size = DEFAULT_SLOT_SIZE;
	s->slot = mtask_malloc(s->slot_size * sizeof(struct mtask_context *));
	memset(s->slot, 0, s->slot_size * sizeof(struct mtask_context *));

	rwlock_init(&s->lock);
	// reserve 0 for system
	s->harbor = (uint32_t) (harbor & 0xff) << HANDLE_REMOTE_SHIFT;
	s->handle_index = 1;// handle句柄从1开始,0保留
	s->name_cap = 2;    // 名字容量初始为2
	s->name_count = 0;
	s->name = mtask_malloc(s->name_cap * sizeof(struct handle_name));

	H = s;

	// Don't need to free H
}

