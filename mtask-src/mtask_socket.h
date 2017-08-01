#ifndef mtask_socket_h
#define mtask_socket_h

#include "mtask.h"

#define MTASK_SOCKET_TYPE_DATA      1
#define MTASK_SOCKET_TYPE_CONNECT   2
#define MTASK_SOCKET_TYPE_CLOSE     3
#define MTASK_SOCKET_TYPE_ACCEPT    4
#define MTASK_SOCKET_TYPE_ERROR     5
#define MTASK_SOCKET_TYPE_UDP       6
#define MTASK_SOCKET_TYPE_WARNING   7

struct mtask_socket_message {
    int type; //消息类型
    int id;   //id
    int ud;
    char * buffer; //数据
};
//初始化socket
void mtask_socket_init();
//退出
void mtask_socket_exit();
//释放
void mtask_socket_free();
//事件循环
int mtask_socket_poll();

int mtask_socket_send(mtask_context_t *ctx, int id, void *buffer, int sz);

int mtask_socket_send_lowpriority(mtask_context_t *ctx, int id, void *buffer, int sz);

int mtask_socket_listen(mtask_context_t *ctx, const char *host, int port, int backlog);

int mtask_socket_connect(mtask_context_t *ctx, const char *host, int port);
// 绑定事件
int mtask_socket_bind(mtask_context_t *ctx, int fd);
// 关闭 Socket
void mtask_socket_close(mtask_context_t *ctx, int id);

void mtask_socket_shutdown(mtask_context_t *ctx, int id);

// 启动 Socket 加入事件循环
void mtask_socket_start(mtask_context_t *ctx, int id);

void mtask_socket_nodelay(mtask_context_t *ctx, int id);

int mtask_socket_udp(mtask_context_t *ctx, const char * addr, int port);

int mtask_socket_udp_connect(mtask_context_t *ctx, int id, const char * addr, int port);

int mtask_socket_udp_send(mtask_context_t *ctx, int id, const char * address, const void *buffer, int sz);

const char * mtask_socket_udp_address(struct mtask_socket_message *, int *addrsz);

#endif
