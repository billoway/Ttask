#ifndef mtask_socket_server_h
#define mtask_socket_server_h

#include <stdint.h>

#define SOCKET_DATA         0 // data 到来
#define SOCKET_CLOSE        1 // close conn
#define SOCKET_OPEN         2 // conn ok
#define SOCKET_ACCEPT       3 //被动连接建立(Accept返回了连接的fd但是未加入epoll来管理)
#define SOCKET_ERROR        4 // error
#define SOCKET_EXIT         5 // exit
#define SOCKET_UDP          6
#define SOCKET_WARNING      7

struct socket_message_s {
	int id;             // 应用层的socket fd
	uintptr_t opaque;   // 在mtask中对应一个actor实体的handler
	int ud;	// for accept, ud is listen id ; for data, ud is size of data 
	char * data;
};

typedef struct socket_message_s socket_message_t;

typedef struct socket_server_s socket_server_t;

socket_server_t * socket_server_create();

void socket_server_release(socket_server_t *);

int socket_server_poll(socket_server_t *, socket_message_t *result, int *more);

void socket_server_exit(socket_server_t *);

void socket_server_close(socket_server_t *, uintptr_t opaque, int id);

void socket_server_shutdown(socket_server_t *, uintptr_t opaque, int id);

void socket_server_start(socket_server_t *, uintptr_t opaque, int id);

// return -1 when error
int socket_server_send(socket_server_t *, int id, const void * buffer, int sz);

int socket_server_send_lowpriority(socket_server_t *, int id, const void * buffer, int sz);

// ctrl command below returns id
int socket_server_listen(socket_server_t *, uintptr_t opaque, const char * addr, int port, int backlog);

int socket_server_connect(socket_server_t *, uintptr_t opaque, const char * addr, int port);

int socket_server_bind(socket_server_t *, uintptr_t opaque, int fd);
// for tcp
void socket_server_nodelay(socket_server_t *, int id);

struct socket_udp_address;

// create an udp socket handle, attach opaque with it . udp socket don't need call socket_server_start to recv message
// if port != 0, bind the socket . if addr == NULL, bind ipv4 0.0.0.0 . If you want to use ipv6, addr can be "::" and port 0.
int socket_server_udp(socket_server_t *, uintptr_t opaque, const char * addr, int port);

// set default dest address, return 0 when success
int socket_server_udp_connect(socket_server_t *, int id, const char * addr, int port);
// If the socket_udp_address is NULL, use last call socket_server_udp_connect address instead
// You can also use socket_server_send 
int socket_server_udp_send(socket_server_t *, int id, const struct socket_udp_address *, const void *buffer, int sz);
// extract the address of the message, socket_message_t * should be SOCKET_UDP
const struct socket_udp_address * socket_server_udp_address(socket_server_t *, socket_message_t *, int *addrsz);

struct socket_object_interface {
	void * (*buffer)(void *);
	int (*size)(void *);
	void (*free)(void *);
};

// if you send package sz == -1, use soi.
void socket_server_userobject(socket_server_t *, struct socket_object_interface *soi);

#endif
