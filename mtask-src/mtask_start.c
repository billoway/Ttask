#include "mtask.h"
#include "mtask_server.h"
#include "mtask_imp.h"
#include "mtask_mq.h"
#include "mtask_handle.h"
#include "mtask_module.h"
#include "mtask_timer.h"
#include "mtask_monitor.h"
#include "mtask_socket.h"
#include "mtask_daemon.h"
#include "mtask_harbor.h"

#include <pthread.h>
#include <unistd.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
//监控结构
struct monitor {
	int count;                  //工作线程数量
	struct mtask_monitor ** m;  //monitor 工作线程监控列表
	pthread_cond_t cond;        //条件变量
	pthread_mutex_t mutex;      //互斥锁
	int sleep;                  //睡眠中工作线程数量
	int quit;
};
//工作线程参数
struct worker_parm {
	struct monitor *m;
	int id;
	int weight;
};

static int SIG = 0;

static void
handle_hup(int signal)
{
    if (signal == SIGHUP) {
        SIG = 1;
    }
}
#define CHECK_ABORT if (mtask_context_total()==0) break;

static void
create_thread(pthread_t *thread, void *(*start_routine) (void *), void *arg)
{
	if (pthread_create(thread,NULL, start_routine, arg)) {
		fprintf(stderr, "Create thread failed");
		exit(1);
	}
}

static void
wakeup(struct monitor *m, int busy) {
	if (m->sleep >= m->count - busy) {
		// signal sleep worker, "spurious wakeup" is harmless
		pthread_cond_signal(&m->cond);
	}
}

static void *
thread_socket(void *p) {
	struct monitor * m = p;
	mtask_initthread(THREAD_SOCKET);
	for (;;) {
		int r = mtask_socket_poll();
		if (r==0)
			break;
		if (r<0) {
			CHECK_ABORT
			continue;
		}
		wakeup(m,0);
	}
	return NULL;
}

static void
free_monitor(struct monitor *m) {
	int i;
	int n = m->count;
	for (i=0;i<n;i++) {
		mtask_monitor_delete(m->m[i]);
	}
	pthread_mutex_destroy(&m->mutex);
	pthread_cond_destroy(&m->cond);
	mtask_free(m->m);
	mtask_free(m);
}

static void *
thread_monitor(void *p) {
	struct monitor * m = p;
	int i;
	int n = m->count;
	mtask_initthread(THREAD_MONITOR);
	for (;;) {
		CHECK_ABORT
		for (i=0;i<n;i++) {
			mtask_monitor_check(m->m[i]);
		}
		for (i=0;i<5;i++) {
			CHECK_ABORT
			sleep(1);
		}
	}

	return NULL;
}

static void *
thread_timer(void *p) {
	struct monitor * m = p;
	mtask_initthread(THREAD_TIMER);
	for (;;) {
		mtask_updatetime();
		CHECK_ABORT
		wakeup(m,m->count-1);
		usleep(2500);
	}
	// wakeup socket thread
	mtask_socket_exit();
	// wakeup all worker thread
	pthread_mutex_lock(&m->mutex);
	m->quit = 1;
	pthread_cond_broadcast(&m->cond);
	pthread_mutex_unlock(&m->mutex);
	return NULL;
}

static void *
thread_worker(void *p) {
	struct worker_parm *wp = p;
	int id = wp->id;
	int weight = wp->weight;
	struct monitor *m = wp->m;
	struct mtask_monitor *sm = m->m[id];
	mtask_initthread(THREAD_WORKER);
	struct message_queue * q = NULL;
	while (!m->quit) {
		q = mtask_context_message_dispatch(sm, q, weight);
		if (q == NULL) {
			if (pthread_mutex_lock(&m->mutex) == 0) {
				++ m->sleep;
				// "spurious wakeup" is harmless,
				// because mtask_context_message_dispatch() can be call at any time.
				if (!m->quit)
					pthread_cond_wait(&m->cond, &m->mutex);
				-- m->sleep;
				if (pthread_mutex_unlock(&m->mutex)) {
					fprintf(stderr, "unlock mutex error");
					exit(1);
				}
			}
		}
	}
	return NULL;
}

static void
start(int thread) {
	pthread_t pid[thread+3];

	struct monitor *m = mtask_malloc(sizeof(*m));
	memset(m, 0, sizeof(*m));
	m->count = thread;
	m->sleep = 0;

	m->m = mtask_malloc(thread * sizeof(struct mtask_monitor *));
	int i;
	for (i=0;i<thread;i++) {
		m->m[i] = mtask_monitor_new();
	}
	if (pthread_mutex_init(&m->mutex, NULL)) {
		fprintf(stderr, "Init mutex error");
		exit(1);
	}
	if (pthread_cond_init(&m->cond, NULL)) {
		fprintf(stderr, "Init cond error");
		exit(1);
	}

	create_thread(&pid[0], thread_monitor, m);
	create_thread(&pid[1], thread_timer, m);
	create_thread(&pid[2], thread_socket, m);

	static int weight[] = { 
		-1, -1, -1, -1, 0, 0, 0, 0,
		1, 1, 1, 1, 1, 1, 1, 1, 
		2, 2, 2, 2, 2, 2, 2, 2, 
		3, 3, 3, 3, 3, 3, 3, 3, };
	struct worker_parm wp[thread];
	for (i=0;i<thread;i++) {
		wp[i].m = m;
		wp[i].id = i;
		if (i < sizeof(weight)/sizeof(weight[0])) {
			wp[i].weight= weight[i];
		} else {
			wp[i].weight = 0;
		}
		create_thread(&pid[i+3], thread_worker, &wp[i]);
	}

	for (i=0;i<thread+3;i++) {
		pthread_join(pid[i], NULL); 
	}

	free_monitor(m);
}

static void
bootstrap(struct mtask_context * logger, const char * cmdline) {
	int sz = (int)strlen(cmdline);
	char name[sz+1];
	char args[sz+1];
	sscanf(cmdline, "%s %s", name, args);
	struct mtask_context *ctx = mtask_context_new(name, args);
	if (ctx == NULL) {
		mtask_error(NULL, "Bootstrap error : %s\n", cmdline);
		mtask_context_dispatchall(logger);
		exit(1);
	}
}
//mtask 启动 传入mtask_config结构体
void
mtask_start(struct mtask_config * config)
{
    // register SIGHUP for log file reopen
    struct sigaction sa;
    sa.sa_handler = &handle_hup;
    sa.sa_flags = SA_RESTART;
    sigfillset(&sa.sa_mask);
    sigaction(SIGHUP, &sa, NULL);
    
	if (config->daemon) {
		if (daemon_init(config->daemon)) {//后台执行
			exit(1);
		}
	}
	mtask_harbor_init(config->harbor);//初始化节点 编号
	mtask_handle_init(config->harbor);//初始化句柄 编号和mtask_context 初始化一个 handle 就是初始化 handle_storage H
	mtask_mq_init();                       //初始化全局队列 Q
	mtask_module_init(config->module_path);//初始化模块管理
	mtask_timer_init();                    //初始化定时器
	mtask_socket_init();

	struct mtask_context *ctx = mtask_context_new(config->logservice, config->logger);
	if (ctx == NULL) {
		fprintf(stderr, "Can't launch %s service\n", config->logservice);
		exit(1);
	}

	bootstrap(ctx, config->bootstrap);

	start(config->thread);

	// harbor_exit may call socket send, so it should exit before socket_free
	mtask_harbor_exit();
	mtask_socket_free();
	if (config->daemon) {
		daemon_exit(config->daemon);
	}
}
