#ifndef luashrtbl_h
#define luashrtbl_h

#include "lstring.h"

// If you use modified lua, this macro would be defined in lstring.h
#ifndef ENABLE_SHORT_STRING_TABLE

static inline int luaS_shrinfo(lua_State *L) { return 0; }
static inline void luaS_initshr() {}
static inline void luaS_exitshr() {}
static inline void luaS_expandshr(int n) {}

#endif

#endif /* luashrtbl_h */
