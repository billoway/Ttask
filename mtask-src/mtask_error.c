#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "mtask.h"
#include "mtask_handle.h"
#include "mtask_mq.h"
#include "mtask_server.h"

#define LOG_MESSAGE_SIZE 256 // 日志的大小

void 
mtask_error(mtask_context_t * context, const char *msg, ...)
{
	static uint32_t logger = 0;
	if (logger == 0) {
		logger = mtask_handle_findname("logger");
	}
	if (logger == 0) {
		return;
	}

	char tmp[LOG_MESSAGE_SIZE];
	char *data = NULL;

	va_list ap;//声明可变参数变量

	va_start(ap,msg); //ap指向msg之后的参数
	int len = vsnprintf(tmp, LOG_MESSAGE_SIZE, msg, ap);
	va_end(ap);
	if (len >=0 && len < LOG_MESSAGE_SIZE) {
		data = mtask_strdup(tmp);// strdup() 将串拷贝到新建的位置处 得到实际的 msg
	} else {
		int max_size = LOG_MESSAGE_SIZE;
		for (;;) {
			max_size *= 2;
			data = mtask_malloc(max_size);// msg 大于 LOG_MESSAGE_SIZE 尝试 分配更大的空间来存放
			va_start(ap,msg);
			len = vsnprintf(data, max_size, msg, ap);//按照msg格式化可变参数ap放在data中，最大长度是max_size
			va_end(ap);
			if (len < max_size) {//写入 data 的数据不比 max_size 大 实际上就是 data能存放msg
				break;
			}
			mtask_free(data);
		}
	}
    if (len < 0) {
        mtask_free(data);
        perror("vsnprintf error :");
        return;
    }


	mtask_message_t smsg;
	if (context == NULL) {
		smsg.source = 0;
	} else {
		smsg.source = mtask_context_handle(context);//ctx->handle
	}
	smsg.session = 0;
	smsg.data = data;
	smsg.sz = len | ((size_t)PTYPE_TEXT << MESSAGE_TYPE_SHIFT);
	mtask_context_push(logger, &smsg);// 将消息发送到对应的 handle 中处理
}

