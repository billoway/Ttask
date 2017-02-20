#ifndef mtask_IMP_H
#define mtask_IMP_H

struct mtask_config {
	int thread;
	int harbor;
	const char * daemon;
	const char * module_path;
	const char * bootstrap;
	const char * logger;
	const char * logservice;
};

#define THREAD_WORKER 0
#define THREAD_MAIN 1
#define THREAD_SOCKET 2
#define THREAD_TIMER 3
#define THREAD_MONITOR 4

void mtask_start(struct mtask_config * config);

#endif
