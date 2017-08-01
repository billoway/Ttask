#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>

#include "mtask.h"

#include "mtask_server.h"
#include "mtask_mq.h"
#include "mtask_harbor.h"
#include "socket_server.h"
#include "mtask_socket.h"

static struct socket_server * SOCKET_SERVER = NULL;

void 
mtask_socket_init()
{
	SOCKET_SERVER = socket_server_create();
}

void
mtask_socket_exit()
{
	socket_server_exit(SOCKET_SERVER);
}

void
mtask_socket_free()
{
	socket_server_release(SOCKET_SERVER);
	SOCKET_SERVER = NULL;
}

// mainloop thread 将数据压入相应服务的消息队列
static void
forward_message(int type, bool padding, struct socket_message * result)
{
    struct mtask_socket_message *sm;
    size_t sz = sizeof(*sm);
    if (padding) {
        if (result->data) {
            size_t msg_sz = strlen(result->data);
            if (msg_sz > 128) {
                msg_sz = 128;
            }
            sz += msg_sz;
        } else {
            result->data = "";
        }
    }
    sm = (struct mtask_socket_message *)mtask_malloc(sz);
    sm->type = type;
    sm->id = result->id;
    sm->ud = result->ud;
    if (padding) {
        sm->buffer = NULL;
        memcpy(sm+1, result->data, sz - sizeof(*sm));
    } else {
        sm->buffer = result->data;
    }
    
    mtask_message_t message;
    message.source = 0;
    message.session = 0;
    message.data = sm;
    message.sz = sz | ((size_t)PTYPE_SOCKET << MESSAGE_TYPE_SHIFT);
    
    if (mtask_context_push((uint32_t)result->opaque, &message)) {
        // todo: report somewhere to close socket
        // don't call mtask_socket_close here (It will block mainloop)
        mtask_free(sm->buffer);
        mtask_free(sm);
    }
}
//检查socket事件 并且做转发
int 
mtask_socket_poll()
{
	struct socket_server *ss = SOCKET_SERVER;
	assert(ss);
	struct socket_message result;
	int more = 1;
    //检测socket事件
	int type = socket_server_poll(ss, &result, &more);
	switch (type) {
        case SOCKET_EXIT:
            return 0;
        //远端有数据发送过来
        case SOCKET_DATA:
            forward_message(MTASK_SOCKET_TYPE_DATA, false, &result);
            break;
        case SOCKET_CLOSE:
            forward_message(MTASK_SOCKET_TYPE_CLOSE, false, &result);
            break;
        //本地打开socket连接进行监听 or 连接建立成功 or 转换网络包目的地址
        case SOCKET_OPEN:
            forward_message(MTASK_SOCKET_TYPE_CONNECT, true, &result);
            break;
        case SOCKET_ERROR:
            forward_message(MTASK_SOCKET_TYPE_ERROR, true, &result);
            break;
        //说明acccpt成功了
        case SOCKET_ACCEPT:
            forward_message(MTASK_SOCKET_TYPE_ACCEPT, true, &result);
            break;
        case SOCKET_UDP:
            forward_message(MTASK_SOCKET_TYPE_UDP, false, &result);
            break;
        case SOCKET_WARNING:
            forward_message(MTASK_SOCKET_TYPE_WARNING, false, &result);
            break;
        default:
            mtask_error(NULL, "Unknown socket message type %d.",type);
            return -1;
    }
	if (more) {
		return -1;
	}
	return 1;
}

int
mtask_socket_send(mtask_context_t *ctx, int id, void *buffer, int sz)
{
    return socket_server_send(SOCKET_SERVER, id, buffer, sz);
}

int
mtask_socket_send_lowpriority(mtask_context_t *ctx, int id, void *buffer, int sz)
{
	return socket_server_send_lowpriority(SOCKET_SERVER, id, buffer, sz);
}

int 
mtask_socket_listen(mtask_context_t *ctx, const char *host, int port, int backlog)
{
    // 哪个服务调用就取得那个服务的地址
	uint32_t source = mtask_context_handle(ctx);
    // 返回的是mtask框架分配的一个id 为s->slot的一个下标，一个数组索引而已
	return socket_server_listen(SOCKET_SERVER, source, host, port, backlog);
}

int 
mtask_socket_connect(mtask_context_t *ctx, const char *host, int port)
{
	uint32_t source = mtask_context_handle(ctx);
	return socket_server_connect(SOCKET_SERVER, source, host, port);
}

int 
mtask_socket_bind(mtask_context_t *ctx, int fd)
{
	uint32_t source = mtask_context_handle(ctx);
	return socket_server_bind(SOCKET_SERVER, source, fd);
}

void 
mtask_socket_close(mtask_context_t *ctx, int id)
{
	uint32_t source = mtask_context_handle(ctx);
	socket_server_close(SOCKET_SERVER, source, id);
}

void
mtask_socket_shutdown(mtask_context_t *ctx, int id)
{
    uint32_t source = mtask_context_handle(ctx);
    socket_server_shutdown(SOCKET_SERVER, source, id);
}

void 
mtask_socket_start(mtask_context_t *ctx, int id)
{
	uint32_t source = mtask_context_handle(ctx);
	socket_server_start(SOCKET_SERVER, source, id);
}

void
mtask_socket_nodelay(mtask_context_t *ctx, int id)
{
	socket_server_nodelay(SOCKET_SERVER, id);
}

int 
mtask_socket_udp(mtask_context_t *ctx, const char * addr, int port)
{
	uint32_t source = mtask_context_handle(ctx);
	return socket_server_udp(SOCKET_SERVER, source, addr, port);
}

int 
mtask_socket_udp_connect(mtask_context_t *ctx, int id, const char * addr, int port)
{
	return socket_server_udp_connect(SOCKET_SERVER, id, addr, port);
}

int 
mtask_socket_udp_send(mtask_context_t *ctx, int id, const char * address, const void *buffer, int sz)
{
    return socket_server_udp_send(SOCKET_SERVER, id, (const struct socket_udp_address *)address, buffer, sz);
}

const char *
mtask_socket_udp_address(struct mtask_socket_message *msg, int *addrsz)
{
	if (msg->type != MTASK_SOCKET_TYPE_UDP) {
		return NULL;
	}
	struct socket_message sm;
	sm.id = msg->id;
	sm.opaque = 0;
	sm.ud = msg->ud;
	sm.data = msg->buffer;
	return (const char *)socket_server_udp_address(SOCKET_SERVER, &sm, addrsz);
}
