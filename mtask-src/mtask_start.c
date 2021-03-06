#include <pthread.h>
#include <unistd.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>

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


//监控结构
struct monitor {
	int count;                  //工作线程数量
	mtask_monitor_t ** m;  //monitor 工作线程监控列表
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
//创建线程
static void
create_thread(pthread_t *thread, void *(*start_routine) (void *), void *arg)
{
	if (pthread_create(thread,NULL, start_routine, arg)) {
		fprintf(stderr, "Create thread failed");
		exit(1);
	}
}
//当睡眠线程的数量 >一定数量才唤醒一个线程
static void
wakeup(struct monitor *m, int busy)
{
	if (m->sleep >= m->count - busy) {
		// signal sleep worker, "spurious wakeup" is harmless
		pthread_cond_signal(&m->cond);
	}
}
//socket线程
static void *
thread_socket(void *p)
{
    pthread_setname_np("thread_socket");
	struct monitor * m = p; //接入monitor结构
	mtask_thread_init(THREAD_SOCKET);//设置线程局部存储 G_NODE.handle_key 为 THREAD_SOCKET
    //检测网络事件（epoll管理的网络事件）并且将事件放入消息队列 mtask_socket_poll--->mtask_context_push
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
//释放监视器
static void
free_monitor(struct monitor *m)
{
	int i;
	int n = m->count;
	for (i=0;i<n;i++) {
		mtask_monitor_delete(m->m[i]);//删除mtask_monitor结构
	}
	pthread_mutex_destroy(&m->mutex);//删除互斥锁
	pthread_cond_destroy(&m->cond); //删除条件变量
	mtask_free(m->m);//释放监视中的mtask_monitor数组指针
	mtask_free(m);   //释放监视结构
}
//监视线程 用于监控是否有消息没有即时处理
//每5秒进行一次检查，看是不是有服务陷入endless
static void *
thread_monitor(void *p)
{
    pthread_setname_np("thread_monitor");

	struct monitor * m = p;
	int i;
	int n = m->count;
	mtask_thread_init(THREAD_MONITOR);
	for (;;) {
		CHECK_ABORT
		for (i=0;i<n;i++) {//遍历监视列表
			mtask_monitor_check(m->m[i]);
		}
		for (i=0;i<5;i++) {//睡眠5秒
			CHECK_ABORT
			sleep(1);
		}
	}

	return NULL;
}
static void
signal_hup()
{
    // make log file reopen
    mtask_message_t smsg;
    smsg.source = 0;
    smsg.session = 0;
    smsg.data = NULL;
    smsg.sz = (size_t)PTYPE_SYSTEM << MESSAGE_TYPE_SHIFT;
    uint32_t logger = mtask_handle_findname("logger");
    if (logger) {
        mtask_context_push(logger, &smsg);
    }
}
//定时器线程
static void *
thread_timer(void *p)
{
    pthread_setname_np("thread_timer");
	struct monitor * m = p;
	mtask_thread_init(THREAD_TIMER);
	for (;;) {
		mtask_time_update();//更新 定时器 的时间
		CHECK_ABORT
		wakeup(m,m->count-1);//只要有一个线程睡眠就唤醒 让工作线程动起来
		usleep(2500);//睡眠2500微妙（1秒=1000000微秒）0.025秒
        if (SIG) {
            signal_hup();
            SIG = 0;
        }
	}
	// wakeup socket thread
	mtask_socket_exit();
	// wakeup all worker thread
	pthread_mutex_lock(&m->mutex);
	m->quit = 1;    //设置退出标志
	pthread_cond_broadcast(&m->cond);//唤醒所有等待条件变量的线程
	pthread_mutex_unlock(&m->mutex);
	return NULL;
}
// 工作线程的作用是从全局的消息队列中取出单个服务的消息队列，再从服务的消息队列中取出消息，
// 然后调用消息的回调函数来处理收到的消息

static void *
thread_worker(void *p)
{
	struct worker_parm *wp = p;
	int id = wp->id;
	int weight = wp->weight;
	struct monitor *m = wp->m;
	mtask_monitor_t *sm = m->m[id];//通过线程id拿到监视器结构（mtask_monitor）
	mtask_thread_init(THREAD_WORKER);
	message_queue_t * q = NULL;
	while (!m->quit) {
        //消息调度执行（取出消息 执行服务中的回调函数）每个服务都有一个权重
		q = mtask_context_message_dispatch(sm, q, weight);
		if (q == NULL) {
			if (pthread_mutex_lock(&m->mutex) == 0) {
				++ m->sleep;//进入睡眠
				// "spurious wakeup" is harmless,
				// because mtask_context_message_dispatch() can be call at any time.
				if (!m->quit)
					pthread_cond_wait(&m->cond, &m->mutex);//没有消息则进入睡眠等待唤醒
				-- m->sleep;//唤醒后减少睡眠线程数量
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
start(int thread)
{
    // 线程数+3 3个线程分别用于 monitor|timer|socket 监控 定时器 socket IO
    pthread_t pid[thread+3];
    
	struct monitor *m = mtask_malloc(sizeof(*m));
	memset(m, 0, sizeof(*m));
	m->count = thread;
	m->sleep = 0;

	m->m = mtask_malloc(thread * sizeof(mtask_monitor_t *));
	int i;
	for (i=0;i<thread;i++) {
		m->m[i] = mtask_monitor_new();//创建mtask_monitor结构放在监视列表 为每个线程新建一个监视
	}
	if (pthread_mutex_init(&m->mutex, NULL)) {
		fprintf(stderr, "Init mutex error");
		exit(1);
	}
	if (pthread_cond_init(&m->cond, NULL)) {
		fprintf(stderr, "Init cond error");
		exit(1);
	}
     //启动线程
	create_thread(&pid[0], thread_monitor, m);
	create_thread(&pid[1], thread_timer, m);
	create_thread(&pid[2], thread_socket, m);
    
    //每个服务都有一个权重
    //权重为-1为只处理一条消息
    //权重为0就将此服务的所有消息处理完
    //权重大于1就处理服务的部分消息
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
        //启动多个线程: thread_worker
		create_thread(&pid[i+3], thread_worker, &wp[i]);
	}

	for (i=0;i<thread+3;i++) {
		pthread_join(pid[i], NULL); 
	}

	free_monitor(m);
}

static void
bootstrap(mtask_context_t * logger, const char * cmdline)
{
	int sz = (int)strlen(cmdline);
	char name[sz+1];
	char args[sz+1];
	sscanf(cmdline, "%s %s", name, args);
    // name为 "snlua" args为 "bootstrap"
	mtask_context_t *ctx = mtask_context_new(name, args);
	if (ctx == NULL) {
        //mtask_error的本质是向logger服务发送消息，第一个参数是服务结构体
		mtask_error(NULL, "Bootstrap error : %s\n", cmdline);
        //取出logger服务的所有消息进行处理
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
    //后台执行
	if (config->daemon) {
		if (daemon_init(config->daemon)) {
			exit(1);
		}
	}
	mtask_harbor_init(config->harbor);//初始化节点编号,用来后续判断是否为非本节点的服务地址
	mtask_handle_init(config->harbor);//初始化句柄编号和mtask_context 初始化一个 handle 就是初始化 handle_storage H
	mtask_mq_init();                       //初始化全局队列 Q
	mtask_module_init(config->module_path);//初始化模块管理，module_path 为C服务的路径
	mtask_timer_init();                    //初始化定时器
	mtask_socket_init();                   //初始化SOCKET_SERVER
    mtask_profile_enable(config->profile);
    //创建第一个服务（C 服务:logger(由于错误消息都是从logger服务写到相应的文件，所以需要先启动logger服务)
	mtask_context_t *ctx = mtask_context_new(config->logservice, config->logger);
	if (ctx == NULL) {
		fprintf(stderr, "Can't launch %s service\n", config->logservice);
		exit(1);
	}
    // 加载 snlua 模块(第二个C 服务)，并启动（snlua 服务启动） bootstrap 服务（第一个 Lua 服务）
	bootstrap(ctx, config->bootstrap);
    //初始化工作基本完成，开启各种线程
	start(config->thread);

	// harbor_exit may call socket send, so it should exit before socket_free
	mtask_harbor_exit();        //节点管理服务退出
	mtask_socket_free();        // 释放网络
	if (config->daemon) {
		daemon_exit(config->daemon);
	}
}
