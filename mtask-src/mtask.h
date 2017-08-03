#ifndef mtask_H
#define mtask_H

#include <stddef.h>
#include <stdint.h>

#include "mtask_malloc.h"

#define PTYPE_TEXT              0  //文本协议
#define PTYPE_RESPONSE          1  //response to client with session, session may be packed into package
#define PTYPE_MULTICAST         2  //组播消息
#define PTYPE_CLIENT            3  //客户端消息
#define PTYPE_SYSTEM            4  //协议控制命令
#define PTYPE_HARBOR            5  //远程消息
#define PTYPE_SOCKET            6  //socket消息
// read lualib/mtask.lua examples/simplemonitor.lua
#define PTYPE_ERROR             7  //错误
// read lualib/mtask.lua lualib/mqueue.lua lualib/snax.lua
#define PTYPE_RESERVED_QUEUE    8
#define PTYPE_RESERVED_DEBUG    9  //调试消息
#define PTYPE_RESERVED_LUA      10 //Lua 消息
#define PTYPE_RESERVED_SNAX     11

#define PTYPE_TAG_DONTCOPY      0x10000 //给自己发消息 TAG
#define PTYPE_TAG_ALLOCSESSION  0x20000 //session 保持唯一的值 0 TAG

//每一个服务对应的 mtask_ctx 结构 mtask上下文结构
typedef struct mtask_context_s mtask_context_t;


void mtask_error(mtask_context_t * context, const char *msg, ...);
// * mtask 提供了一个叫做 mtask_command 的 C API ，作为基础服务的统一入口。
const char * mtask_command(mtask_context_t * context, const char * cmd , const char * parm);

uint32_t mtask_queryname(mtask_context_t * context, const char * name);

/**
 服务之间消息发送API

 @param context   C 基础对象
 
 @param source    消息源，每个服务都由一个 32bit 整数标识。这个整数可以看成是服务在 mtask 系统中的地址。
     即使在服务退出后，新启动的服务通常也不会使用已用过的地址（除非发生回绕，但一般间隔时间非常长）。
     每条收到的消息都携带有 source ，方便在回应的时候可以指定地址。但地址的管理通常由框架完成，用户不用关心。
 @param destination 目标
 @param type 消息类别 ；每个服务可以接收 256 种不同类别的消息，每种类别可以有不同的消息编码格式。
     有十几种类别是框架保留的，通常也不建议用户定义新的消息类别。因为用户完全可以利用已有的类别，而用具体
     的消息内容来区分每条具体的含义。框架把这些 type 映射为字符串便于记忆。最常用的消息类别名为 "lua" 
     广泛用于用 lua 编写的 mtask 服务间的通讯
 @param session 会话ID，大部分消息工作在请求回应模式下，一个服务向另一个服务发起一个请求，
     而后收到请求的服务在处理完请求消息后，回复一条消息 ，session 是由发起请求的服务生成的，
     对它自己唯一的消息标识。回应方在回应时，将 session 带回。这样发送方才能识别出哪条消息是针对哪条的回应。
     session 是一个非负整数，当一条消息不需要回应时，按惯例，使用 0 这个特殊的 session 号。
     session 由 mtask 框架生成管理，通常不需要使用者关心。
 @param msg 消息的 C 指针,在 Lua 层看来是一个 lightuserdata。
     框架会隐藏这个细节，最终用户处理的是经过解码过的 lua 对象。
 @param sz 消息的长度。通常和 message 一起结合起来使用。
 @return -1 or  session
 */
int mtask_send(mtask_context_t * context, uint32_t source, uint32_t destination , int type, int session, void * msg, size_t sz);

int mtask_sendname(mtask_context_t * context, uint32_t source, const char * destination , int type, int session, void * msg, size_t sz);

int mtask_isremote(mtask_context_t *, uint32_t handle, int * harbor);

typedef int (*mtask_cb)(mtask_context_t * context, void *ud, int type, int session, uint32_t source , const void * msg, size_t sz);

void mtask_callback(mtask_context_t * context, void *ud, mtask_cb cb);

uint32_t mtask_current_handle(void);

uint64_t mtask_now(void);

void mtask_debug_memory(const char *info);	// for debug use, output current service memory to stderr

#endif
