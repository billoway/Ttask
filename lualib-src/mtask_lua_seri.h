#ifndef LUA_SERIALIZE_H
#define LUA_SERIALIZE_H

/**
 当我们能确保消息仅在同一进程间流通的时候，便可以直接把 C 对象编码成一个指针。
 因为进程相同，所以 C 指针可以有效传递。但是，mtask 默认支持有多节点模式，
 消息有可能被传到另一台机器的另一个进程中。这种情况下，每条消息都必须是一块连续内存，
 我们就必须对消息进行序列化操作。
 
 mtask 默认提供了一套对 lua 数据结构的序列化方案。
 即 mtask.pack 以及 mtask.unpack 函数。
 mtask.pack 可以将一组 lua 对象序列化为一个由 malloc 分配出来的 C 指针加一个数字长度。
 你需要考虑 C 指针引用的数据块何时释放的问题。当然，如果你只是将 mtask.pack 填在消息处理框架
 里时，框架解决了这个管理问题。mtask 将 C 指针发送到其他服务，而接收方会在使用完后释放这个指针。
 
 如果你想把这个序列化模块做它用，建议使用另一个 api mtask.packstring 。
 和 mtask.pack 不同，它返回一个 lua string 。而 mtask.unpack 即可以处理 C 指针，也可以处理 lua string 。
 
 这个序列化库支持 string, boolean, number, lightuserdata, table 这些类型，
 但对 lua table 的 metatable 支持非常有限，所以尽量不要用其打包带有元方法的 lua 对象。
 
 */
#include <lua.h>

int luaseri_pack(lua_State *L);
int luaseri_unpack(lua_State *L);

#endif
