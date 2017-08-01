#ifndef mtask_SPINLOCK_H
#define mtask_SPINLOCK_H


#define SPIN_INIT(q) spinlock_init(&(q)->lock);
#define SPIN_LOCK(q) spinlock_lock(&(q)->lock);
#define SPIN_UNLOCK(q) spinlock_unlock(&(q)->lock);
#define SPIN_DESTROY(q) spinlock_destroy(&(q)->lock);

#ifndef USE_PTHREAD_LOCK

//原子操作的自旋锁不会切换线程上下文（睡眠），所以自旋锁的加锁效率要更高，但是也会导致CPU使用率增高
struct spinlock_s {
    int lock;
};
typedef struct spinlock_s spinlock_t;


static inline void
spinlock_init(spinlock_t *lock)
{
    lock->lock = 0;
}

static inline void
spinlock_lock(spinlock_t *lock)
{
    while (__sync_lock_test_and_set(&lock->lock,1)) {} //__sync_lock_test_and_set原子操作 实现循环检测的自旋锁（spinlock）
}

static inline int
spinlock_trylock(spinlock_t *lock)
{
    return __sync_lock_test_and_set(&lock->lock,1) == 0;
}

static inline void
spinlock_unlock(spinlock_t *lock)
{
    __sync_lock_release(&lock->lock);
}

static inline void
spinlock_destroy(spinlock_t *lock)
{
    (void) lock;
}

#else

#include <pthread.h>

// we use mutex instead of spinlock for some reason
// you can also replace to pthread_spinlock

spinlock_t {
    pthread_mutex_t lock;//mutex实现的自旋锁
};

static inline void
spinlock_init(spinlock_t *lock)
{
    pthread_mutex_init(&lock->lock, NULL);
}

static inline void
spinlock_lock(spinlock_t *lock)
{
    pthread_mutex_lock(&lock->lock);
}

static inline int
spinlock_trylock(spinlock_t *lock)
{
    return pthread_mutex_trylock(&lock->lock) == 0;
}

static inline void
spinlock_unlock(spinlock_t *lock)
{
    pthread_mutex_unlock(&lock->lock);
}

static inline void
spinlock_destroy(spinlock_t *lock)
{
    pthread_mutex_destroy(&lock->lock);
}

#endif

#endif
