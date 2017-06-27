#ifndef mtask_socket_h
#define mtask_socket_h

struct mtask_context;

#define MTASK_SOCKET_TYPE_DATA 1
#define MTASK_SOCKET_TYPE_CONNECT 2
#define MTASK_SOCKET_TYPE_CLOSE 3
#define MTASK_SOCKET_TYPE_ACCEPT 4
#define MTASK_SOCKET_TYPE_ERROR 5
#define MTASK_SOCKET_TYPE_UDP 6
#define MTASK_SOCKET_TYPE_WARNING 7

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

int mtask_socket_send(struct mtask_context *ctx, int id, void *buffer, int sz);

void mtask_socket_send_lowpriority(struct mtask_context *ctx, int id, void *buffer, int sz);

int mtask_socket_listen(struct mtask_context *ctx, const char *host, int port, int backlog);

int mtask_socket_connect(struct mtask_context *ctx, const char *host, int port);
// 绑定事件
int mtask_socket_bind(struct mtask_context *ctx, int fd);
// 关闭 Socket
void mtask_socket_close(struct mtask_context *ctx, int id);

void mtask_socket_shutdown(struct mtask_context *ctx, int id);

// 启动 Socket 加入事件循环
void mtask_socket_start(struct mtask_context *ctx, int id);

void mtask_socket_nodelay(struct mtask_context *ctx, int id);

int mtask_socket_udp(struct mtask_context *ctx, const char * addr, int port);

int mtask_socket_udp_connect(struct mtask_context *ctx, int id, const char * addr, int port);

int mtask_socket_udp_send(struct mtask_context *ctx, int id, const char * address, const void *buffer, int sz);

const char * mtask_socket_udp_address(struct mtask_socket_message *, int *addrsz);

#endif
