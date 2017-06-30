include platform.mk

LUA_CLIB_PATH ?= luaclib
CSERVICE_PATH ?= cservice

MTASK_BUILD_PATH ?= .
# debug 不开-O2
CFLAGS = -g  -Wall -I$(LUA_INC) $(MYCFLAGS) 
# CFLAGS += -DUSE_PTHREAD_LOCK

# lua

LUA_STATICLIB := 3rd/lua/liblua.a
LUA_LIB ?= $(LUA_STATICLIB)
LUA_INC ?= 3rd/lua

$(LUA_STATICLIB) :
	cd 3rd/lua && $(MAKE) CC='$(CC) -std=gnu99' $(PLAT)

# jemalloc 

JEMALLOC_STATICLIB := 3rd/jemalloc/lib/libjemalloc_pic.a
JEMALLOC_INC := 3rd/jemalloc/include/jemalloc

all : jemalloc
	
.PHONY : jemalloc

MALLOC_STATICLIB := $(JEMALLOC_STATICLIB)

$(JEMALLOC_STATICLIB) : 3rd/jemalloc/Makefile
	cd 3rd/jemalloc && $(MAKE) CC=$(CC) 

3rd/jemalloc/autogen.sh :
	git submodule update --init

3rd/jemalloc/Makefile : | 3rd/jemalloc/autogen.sh
	cd 3rd/jemalloc && ./autogen.sh --with-jemalloc-prefix=je_ --disable-valgrind

jemalloc : $(MALLOC_STATICLIB)

# mtask

CSERVICE = snlua logger gate harbor
LUA_CLIB = mtask socketdriver bson mongo md5 netpack \
  clientsocket memory profile multicast \
  cluster crypt sharedata stm sproto lpeg \
  mysqlaux debugchannel

MTASK_SRC = mtask_main.c mtask_handle.c mtask_module.c mtask_mq.c \
  mtask_server.c mtask_start.c mtask_timer.c mtask_error.c \
  mtask_harbor.c mtask_env.c mtask_monitor.c mtask_socket.c socket_server.c \
  malloc_hook.c mtask_daemon.c mtask_log.c

all : \
  $(MTASK_BUILD_PATH)/mtask \
  $(foreach v, $(CSERVICE), $(CSERVICE_PATH)/$(v).so) \
  $(foreach v, $(LUA_CLIB), $(LUA_CLIB_PATH)/$(v).so) 

$(MTASK_BUILD_PATH)/mtask : $(foreach v, $(MTASK_SRC), mtask-src/$(v)) $(LUA_LIB) $(MALLOC_STATICLIB)
	$(CC) $(CFLAGS) -o $@ $^ -Imtask-src -I$(JEMALLOC_INC) $(LDFLAGS) $(EXPORT) $(MTASK_LIBS) $(MTASK_DEFINES)

$(LUA_CLIB_PATH) :
	mkdir $(LUA_CLIB_PATH)

$(CSERVICE_PATH) :
	mkdir $(CSERVICE_PATH)

define CSERVICE_TEMP
  $$(CSERVICE_PATH)/$(1).so : service-src/mtask_service_$(1).c | $$(CSERVICE_PATH)
		$$(CC) $$(CFLAGS) $$(SHARED) $$< -o $$@ -Imtask-src
endef

$(foreach v, $(CSERVICE), $(eval $(call CSERVICE_TEMP,$(v))))

$(LUA_CLIB_PATH)/mtask.so : lualib-src/mtask_lua_mtask.c lualib-src/mtask_lua_seri.c | $(LUA_CLIB_PATH)
		$(CC) $(CFLAGS) $(SHARED) $^ -o $@ -Imtask-src -Iservice-src -Ilualib-src

$(LUA_CLIB_PATH)/socketdriver.so : lualib-src/mtask_lua_socket.c | $(LUA_CLIB_PATH)
		$(CC) $(CFLAGS) $(SHARED) $^ -o $@ -Imtask-src -Iservice-src

$(LUA_CLIB_PATH)/bson.so : lualib-src/mtask_lua_bson.c | $(LUA_CLIB_PATH)
		$(CC) $(CFLAGS) $(SHARED) $^ -o $@ -Imtask-src

$(LUA_CLIB_PATH)/mongo.so : lualib-src/mtask_lua_mongo.c | $(LUA_CLIB_PATH)
		$(CC) $(CFLAGS) $(SHARED) $^ -o $@ -Imtask-src

$(LUA_CLIB_PATH)/md5.so : 3rd/lua-md5/md5.c 3rd/lua-md5/md5lib.c 3rd/lua-md5/compat-5.2.c | $(LUA_CLIB_PATH)
		$(CC) $(CFLAGS) $(SHARED) -I3rd/lua-md5 $^ -o $@ 

$(LUA_CLIB_PATH)/netpack.so : lualib-src/mtask_lua_netpack.c | $(LUA_CLIB_PATH)
		$(CC) $(CFLAGS) $(SHARED) $^ -Imtask-src -o $@ 

$(LUA_CLIB_PATH)/clientsocket.so : lualib-src/mtask_lua_clientsocket.c | $(LUA_CLIB_PATH)
		$(CC) $(CFLAGS) $(SHARED) $^ -o $@ -lpthread

$(LUA_CLIB_PATH)/memory.so : lualib-src/mtask_lua_memory.c | $(LUA_CLIB_PATH)
		$(CC) $(CFLAGS) $(SHARED) -Imtask-src $^ -o $@ 

$(LUA_CLIB_PATH)/profile.so : lualib-src/mtask_lua_profile.c | $(LUA_CLIB_PATH)
		$(CC) $(CFLAGS) $(SHARED)  $^ -o $@ 

$(LUA_CLIB_PATH)/multicast.so : lualib-src/mtask_lua_multicast.c | $(LUA_CLIB_PATH)
		$(CC) $(CFLAGS) $(SHARED) -Imtask-src $^ -o $@ 

$(LUA_CLIB_PATH)/cluster.so : lualib-src/mtask_lua_cluster.c | $(LUA_CLIB_PATH)
		$(CC) $(CFLAGS) $(SHARED) -Imtask-src $^ -o $@ 

$(LUA_CLIB_PATH)/crypt.so : lualib-src/mtask_lua_crypt.c lualib-src/lsha1.c | $(LUA_CLIB_PATH)
		$(CC) $(CFLAGS) $(SHARED)  $^ -o $@ 

$(LUA_CLIB_PATH)/sharedata.so : lualib-src/mtask_lua_sharedata.c | $(LUA_CLIB_PATH)
		$(CC) $(CFLAGS) $(SHARED) -Imtask-src $^ -o $@ 

$(LUA_CLIB_PATH)/stm.so : lualib-src/mtask_lua_stm.c | $(LUA_CLIB_PATH)
		$(CC) $(CFLAGS) $(SHARED) -Imtask-src $^ -o $@ 

$(LUA_CLIB_PATH)/sproto.so : lualib-src/sproto/sproto.c lualib-src/sproto/lsproto.c | $(LUA_CLIB_PATH)
		$(CC) $(CFLAGS) $(SHARED) -Ilualib-src/sproto $^ -o $@ 

$(LUA_CLIB_PATH)/lpeg.so : 3rd/lpeg/lpcap.c 3rd/lpeg/lpcode.c 3rd/lpeg/lpprint.c 3rd/lpeg/lptree.c 3rd/lpeg/lpvm.c | $(LUA_CLIB_PATH)
		$(CC) $(CFLAGS) $(SHARED) -I3rd/lpeg $^ -o $@ 
										  
$(LUA_CLIB_PATH)/mysqlaux.so : lualib-src/mtask_lua_mysqlaux.c | $(LUA_CLIB_PATH)
		$(CC) $(CFLAGS) $(SHARED) $^ -o $@

$(LUA_CLIB_PATH)/debugchannel.so : lualib-src/mtask_lua_debugchannel.c | $(LUA_CLIB_PATH)
		$(CC) $(CFLAGS) $(SHARED) -Imtask-src  $^ -o $@

clean :
		rm -f $(MTASK__BUILD_PATH)/mtask $(CSERVICE_PATH)/*.so $(LUA_CLIB_PATH)/*.so

cleanall: clean
ifneq (,$(wildcard 3rd/jemalloc/Makefile))
		cd 3rd/jemalloc && $(MAKE) clean
endif
		cd 3rd/lua && $(MAKE) clean
		rm -f $(LUA_STATICLIB)
