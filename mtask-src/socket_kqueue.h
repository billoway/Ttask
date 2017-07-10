#ifndef poll_socket_kqueue_h
#define poll_socket_kqueue_h

#include <netdb.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/event.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

//Free BSD 上实现的一种io多路复用技术
//epoll和kqueue的比较:非文件类型支持 磁盘文件支持
static bool 
sp_invalid(int kfd)
{
	return kfd == -1;
}
//生成kqueue专用的文件描述符。是在内核申请一空间，存放关注的socket fd上是否发生以及发生了什么事件。
static int
sp_create()
{
	return kqueue();
}
//关闭kqueue句柄
static void
sp_release(int kfd)
{
	close(kfd);
}
//从kfd中删除一个fd
static void 
sp_del(int kfd, int sock)
{
	struct kevent ke;
	EV_SET(&ke, sock, EVFILT_READ, EV_DELETE, 0, 0, NULL);
	kevent(kfd, &ke, 1, NULL, 0, NULL);
	EV_SET(&ke, sock, EVFILT_WRITE, EV_DELETE, 0, 0, NULL);
	kevent(kfd, &ke, 1, NULL, 0, NULL);
}
//将被监听的描述符添加到kqueue句柄或从kqueue句柄中删除或者对监听事件进行修改
//注册新的fd到kfd中
static int
sp_add(int kfd, int sock, void *ud)
{
	struct kevent ke;
	EV_SET(&ke, sock, EVFILT_READ, EV_ADD, 0, 0, ud);
	if (kevent(kfd, &ke, 1, NULL, 0, NULL) == -1 ||	ke.flags & EV_ERROR) {
		return 1;
	}
	EV_SET(&ke, sock, EVFILT_WRITE, EV_ADD, 0, 0, ud);
	if (kevent(kfd, &ke, 1, NULL, 0, NULL) == -1 ||	ke.flags & EV_ERROR) {
		EV_SET(&ke, sock, EVFILT_READ, EV_DELETE, 0, 0, NULL);
		kevent(kfd, &ke, 1, NULL, 0, NULL);
		return 1;
	}
	EV_SET(&ke, sock, EVFILT_WRITE, EV_DISABLE, 0, 0, ud);
	if (kevent(kfd, &ke, 1, NULL, 0, NULL) == -1 ||	ke.flags & EV_ERROR) {
		sp_del(kfd, sock);
		return 1;
	}
	return 0;
}
//EVFILT_READ:表示对应的文件描述符上有可读数据
//EVFILT_WRITE:表示对应的文件描述符上可以写数据
static void 
sp_write(int kfd, int sock, void *ud, bool enable)
{
	struct kevent ke;
	EV_SET(&ke, sock, EVFILT_WRITE, enable ? EV_ENABLE : EV_DISABLE, 0, 0, ud);
if (kevent(kfd, &ke, 1, NULL, 0, NULL) == -1 || ke.flags & EV_ERROR) {
		// todo: check error
	}
}
//kevent ev:用于回传待处理事件的数组；

static int 
sp_wait(int kfd, struct event *e, int max)
{
	struct kevent ev[max];
	int n = kevent(kfd, NULL, 0, ev, max, NULL);//等待事件触发，当超过timeout还没有事件触发时，就超时 返回事件数量和事件集合

    //等侍注册在kfd上的socket fd的事件的发生，如果发生则将发生的sokct fd和事件类型放入到ev数组中。
    //并且将注册在kfd上的socket fd的事件类型给清空，所以如果下一个循环你还要关注这个socket fd的话，需要重新设置socket fd的事件类型

	int i;
	for (i=0;i<n;i++) {
		e[i].s = ev[i].udata;
		unsigned filter = ev[i].filter;
		e[i].write = (filter == EVFILT_WRITE);
		e[i].read = (filter == EVFILT_READ);
		e[i].error = false;	// kevent has not error event
	}

	return n;
}
//设置文件描述符非阻塞状态
static void
sp_nonblocking(int fd)
{
	int flag = fcntl(fd, F_GETFL, 0);
	if ( -1 == flag ) {
		return;
	}

	fcntl(fd, F_SETFL, flag | O_NONBLOCK);
}

#endif
