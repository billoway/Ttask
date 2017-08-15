local driver = require "mtask.socketdriver"
local mtask = require "mtask"
local mtask_core = require "mtask.core"
local assert = assert

--[[
阻塞模式的 lua API 用于 TCP socket 的读写。
它是对 C API 的封装(C API 采用异步读写，你可以使用 C 调用，监听一个端口，或发起一个 TCP 连接。
但具体的操作结果要等待 mtask 的事件回调。
mtask 会把结果以 PTYPE_SOCKET 类型的消息发送给发起请求的服务)

如果你需要一个网关帮你接入大量连接并转发它们到不同的地方处理。
service/gate.lua 可以直接使用，同时也是用于了解  socket 模块如何工作的不错的参考。
它还有一个功能近似的，但是全部用 C 编写的版本 service-src/mtask_service_gate.c 。
]]

local socket = {}	-- api
local buffer_pool = {}	-- store all message buffer object
local socket_pool = setmetatable( -- store all socket object
	{},
	{ __gc = function(p)
		for id,v in pairs(p) do
			driver.close(id)
			-- don't need clear v.buffer, because buffer pool will be free at the end
			p[id] = nil
		end
	end
	}
)

local socket_message = {}

local function wakeup(s)
	local co = s.co
	if co then
		s.co = nil
		mtask.wakeup(co)
	end
end

local function suspend(s)
	assert(not s.co)
	s.co = coroutine.running()
	mtask.wait(s.co)
	-- wakeup closing corouting every time suspend,
	-- because socket.close() will wait last socket buffer operation before clear the buffer.
	if s.closing then
		mtask.wakeup(s.closing)
	end
end

-- read mtask_socket.h for these macro
-- MTASK_SOCKET_TYPE_DATA = 1
-- 从远端过来的消息会进入 socket_message[1] 函数进行处理
socket_message[1] = function(id, size, data)
	local s = socket_pool[id]
	if s == nil then
		mtask.error("socket: drop package from " .. id)
		driver.drop(data, size)
		return
	end

	local sz = driver.push(s.buffer, buffer_pool, data, size)
	-- 将接收到的数据放到buffer里面
	local rr = s.read_required
	local rrt = type(rr)
	if rrt == "number" then
		-- read size
		if sz >= rr then
			s.read_required = nil
			wakeup(s)
		end
	else
		if s.buffer_limit and sz > s.buffer_limit then
			mtask.error(string.format("socket buffer overflow: fd=%d size=%d", id , sz))
			driver.clear(s.buffer,buffer_pool)
			driver.close(id)
			return
		end
		if rrt == "string" then
			-- read line
			if driver.readline(s.buffer,nil,rr) then
				s.read_required = nil
				wakeup(s)
			end
		end
	end
end

-- 收到此消息以后，调用 wakeup 唤醒 socket.open 中的 connect，connect 会返回。
-- 所以 socket.open 相当于阻塞模式的connect函数。
-- MTASK_SOCKET_TYPE_CONNECT = 2
socket_message[2] = function(id, _ , addr)
	local s = socket_pool[id]
	if s == nil then
		return
	end
	-- log remote addr
	s.connected = true
	wakeup(s)
end

-- mtask_SOCKET_TYPE_CLOSE = 3
socket_message[3] = function(id)
	local s = socket_pool[id]
	if s == nil then
		return
	end
	s.connected = false
	wakeup(s)
end

-- mtask_SOCKET_TYPE_ACCEPT = 4
socket_message[4] = function(id, newid, addr)
	local s = socket_pool[id]
	if s == nil then
		driver.close(newid)
		return
	end
	s.callback(newid, addr)
end

-- mtask_SOCKET_TYPE_ERROR = 5
socket_message[5] = function(id, _, err)
	local s = socket_pool[id]
	if s == nil then
		mtask.error("socket: error on unknown", id, err)
		return
	end
	if s.connected then
		mtask.error("socket: error on", id, err)
	elseif s.connecting then
		s.connecting = err
	end
	s.connected = false
	driver.shutdown(id)

	wakeup(s)
end

-- mtask_SOCKET_TYPE_UDP = 6
socket_message[6] = function(id, size, data, address)
	local s = socket_pool[id]
	if s == nil or s.callback == nil then
		mtask.error("socket: drop udp package from " .. id)
		driver.drop(data, size)
		return
	end
	local str = mtask.tostring(data, size)
	mtask_core.trash(data, size)
	s.callback(str, address)
end

local function default_warning(id, size)
	local s = socket_pool[id]
	if not s then
		return
	end
	mtask.error(string.format("WARNING: %d K bytes need to send out (fd = %d)", size, id))
end

-- mtask_SOCKET_TYPE_WARNING
socket_message[7] = function(id, size)
	local s = socket_pool[id]
	if s then
		local warning = s.on_warning or default_warning
		warning(id, size)
	end
end
--其中t是从底层(C 层)的 forward_message 中传递过来的，是一个枚举变量(从1-7)，
--也就是说调用的socket.lua的服务都会注册这样一个"socket"类型的消息处理函数。
mtask.register_protocol {
	name = "socket",
	id = mtask.PTYPE_SOCKET,	-- PTYPE_SOCKET = 6
	unpack = driver.unpack,
	dispatch = function (_, _, t, ...)
		socket_message[t](...)
	end
}
-- 初始化 buffer，创建 socket_pool 对应的 id 结构
-- 会阻塞，然后等相应的动作完成后才能返回
-- connect函数会创建一个table对应每个socket描述符，此table里面会有一个 callback. 
-- suspend 函数顾名思义会挂起正在执行的协程。
local function connect(id, func)
	local newbuffer
	if func == nil then
		newbuffer = driver.buffer()
	end
	local s = {
		id = id,
		buffer = newbuffer,		-- 缓冲区(此socket库的实现原理是:远端发送消息过来，会收到数据，收到数据以后将数据全部储存在此buffer中，如果需要读取，则直接从此缓冲区中读取即可)
		connected = false,
		connecting = true,
		read_required = false,
		co = false,
		callback = func,	-- 主动监听的一方如果被远端连接了，那么调用此函数(参数为 (已连接描述符 "远端ip:端口"))
		protocol = "TCP",
	}
	assert(not socket_pool[id], "socket is not closed")
	socket_pool[id] = s
	suspend(s)
	local err = s.connecting
	s.connecting = nil
	if s.connected then
		return id
	else
		socket_pool[id] = nil
		return nil, err
	end
end
--  主动连接， 建立一个 TCP 连接。返回一个数字 id 。
-- driver.connect 函数在底层会向管道发送一个 'O' 的命令，然后挂起当前的协程；
-- 管道的读端收到 'O' 后会调用 connect 函数主动与远端连接，如果连接建立成功，会收到"socket"类型的消息(forward_message)， 消息处理函数中的 t 为 MTASK_SOCKET_TYPE_CONNECT
function socket.open(addr, port)
	-- 此函数在底层会向管道发送一个 'O' 的命令，管道的读端收到 'O' 后会调用 connect 函数主动与远端建立起连接
	local id = driver.connect(addr,port)
	return connect(id)
end
-- 将操作系统的句柄交给底层的 epoll|kqueue 来管理，有数据来了也走 socket 那一套
-- driver.bind 会向管道发送一个 "B"，管道的读端收到后:
function socket.bind(os_fd)
	local id = driver.bind(os_fd)
	return connect(id)
end

function socket.stdin()
	return socket.bind(0)
end
--func 是一个函数。
--每当一个监听的 id 对应的 socket 上有连接接入的时候，都会调用 func 函数。
--这个函数会得到接入连接的 id 以及 ip 地址。你可以做后续操作。
--每当 func 函数获得一个新的 socket id 后，并不会立即收到这个 socket 上的数据。
--这是因为，我们有时会希望把这个 socket 的操作权转让给别的服务去处理。
--socket 的 id 对于整个 mtask 节点都是公开的。
--也就是说，你可以把 id 这个数字通过消息发送给其它服务，其他服务也可以去操作它。
--任何一个服务只有在调用 socket.start(id) 之后，才可以收到这个 socket 上的数据。
--框架是根据调用 start 这个 api 的位置来决定把对应 socket 上的数据转发到哪里去的。

--向一个 socket id 写数据也需要先调用 start ，但写数据不限制在调用 start 的同一个服务中。
--也就是说，你可以在一个服务中调用 start ，然后在另一个服务中向其写入数据。
--框架 可以保证一次 write 调用的原子性。
--即，如果你有多个服务同时向一个 socket id 写数据，每个写操作的串不会被分割开。

-- 一般是主动监听的一端在调用 socket.listen 后调用此函数
function socket.start(id, func)
	driver.start(id)
	return connect(id, func)
end

local function close_fd(id, func)
	local s = socket_pool[id]
	if s then
		driver.clear(s.buffer,buffer_pool)
		-- the framework would send MTASK_SOCKET_TYPE_CLOSE , need close(id) later
		driver.shutdown(id)
	end
end


--在极其罕见的情况下，需要粗暴的直接关闭某个连接，而避免 socket.close 的阻塞等待流程，可以使用它。
function socket.close_fd(id)
	assert(socket_pool[id] == nil,"Use socket.close instead")
	driver.close(id)
end
--关闭一个连接，这个 API 有可能阻塞住执行流。
--因为如果有其它 coroutine 正在阻塞读这个 id 对应的连接，会先驱使读操作结束，close 操作才返回。
function socket.close(id)
	local s = socket_pool[id]
	if s == nil then
		return
	end
	if s.connected then
		driver.close(id)
		-- notice: call socket.close in __gc should be carefully,
		-- because mtask.wait never return in __gc, so driver.clear may not be called
		if s.co then
			-- reading this socket on another coroutine, so don't shutdown (clear the buffer) immediately
			-- wait reading coroutine read the buffer.
			assert(not s.closing)
			s.closing = coroutine.running()
			mtask.wait(s.closing)
		else
			suspend(s)
		end
		s.connected = false
	end
	driver.clear(s.buffer,buffer_pool)
	assert(s.lock == nil or next(s.lock) == nil)
	socket_pool[id] = nil
end

function socket.disconnected(id)
	local s = socket_pool[id]
	if s then
		return not(s.connected or s.connecting)
	end
end

--从一个 socket 上读 sz 指定的字节数。
--如果读到了指定长度的字符串，它把这个字符串返回。
--如果连接断开导致字节数不够，将返回一个 false 加上读到的字符串。
--如果 sz 为 nil ，则返回尽可能多的字节数，但至少读一个字节（若无新数据，会阻塞）。
function socket.read(id, sz)
	local s = socket_pool[id]
	assert(s)
	if sz == nil then
		-- read some bytes
		local ret = driver.readall(s.buffer, buffer_pool)
		if ret ~= "" then
			return ret
		end

		if not s.connected then
			return false, ret
		end
		assert(not s.read_required)
		s.read_required = 0
		suspend(s)
		ret = driver.readall(s.buffer, buffer_pool)
		if ret ~= "" then
			return ret
		else
			return false, ret
		end
	end

	local ret = driver.pop(s.buffer, buffer_pool, sz)
	if ret then
		return ret
	end
	if not s.connected then
		return false, driver.readall(s.buffer, buffer_pool)
	end

	assert(not s.read_required)
	s.read_required = sz
	suspend(s)
	ret = driver.pop(s.buffer, buffer_pool, sz)
	if ret then
		return ret
	else
		return false, driver.readall(s.buffer, buffer_pool)
	end
end
--从一个 socket 上读所有的数据，直到 socket 主动断开，
--或在其它 coroutine 用 socket.close 关闭它。
function socket.readall(id)
	local s = socket_pool[id]
	assert(s)
	if not s.connected then
		local r = driver.readall(s.buffer, buffer_pool)
		return r ~= "" and r
	end
	assert(not s.read_required)
	s.read_required = true
	suspend(s)
	assert(s.connected == false)
	return driver.readall(s.buffer, buffer_pool)
end
--从一个 socket 上读一行数据。sep 指行分割符。
--默认的 sep 为 "\n"。读到的字符串是不包含这个分割符的。
function socket.readline(id, sep)
	sep = sep or "\n"
	local s = socket_pool[id]
	assert(s)
	local ret = driver.readline(s.buffer, buffer_pool, sep)
	if ret then
		return ret
	end
	if not s.connected then
		return false, driver.readall(s.buffer, buffer_pool)
	end
	assert(not s.read_required)
	s.read_required = sep
	suspend(s)
	if s.connected then
		return driver.readline(s.buffer, buffer_pool, sep)
	else
		return false, driver.readall(s.buffer, buffer_pool)
	end
end
--等待一个 socket 可读 (等待缓冲区区中有数据)
function socket.block(id)
	local s = socket_pool[id]
	if not s or not s.connected then
		return false
	end
	assert(not s.read_required)
	s.read_required = 0
	suspend(s)
	return s.connected
end

socket.write = assert(driver.send)
socket.lwrite = assert(driver.lsend)
socket.header = assert(driver.header)

function socket.invalid(id)
	return socket_pool[id] == nil
end
-- 监听一个地址与端口，等待远端连接过来，此函数一般与 socket.start(id, func) 配合使用
-- 其中 socket.start 第一个参数为监听描述符，第二个参数为一个函数，函数的参数为:(已连接描述符 "远端地址:端口")
function socket.listen(host, port, backlog)
	if port == nil then
		host, port = string.match(host, "([^:]+):(.+)$")
		port = tonumber(port)
	end
	-- 此函数底层的动作为:给管道发送一个 'L' 命令，调用 bing listen 函数
	return driver.listen(host, port, backlog)
end

function socket.lock(id)
	local s = socket_pool[id]
	assert(s)
	local lock_set = s.lock
	if not lock_set then
		lock_set = {}
		s.lock = lock_set
	end
	if #lock_set == 0 then
		lock_set[1] = true
	else
		local co = coroutine.running()
		table.insert(lock_set, co)
		mtask.wait(co)
	end
end

function socket.unlock(id)
	local s = socket_pool[id]
	assert(s)
	local lock_set = assert(s.lock)
	table.remove(lock_set,1)
	local co = lock_set[1]
	if co then
		mtask.wakeup(co)
	end
end
--清除 socket id 在本服务内的数据结构，但并不关闭这个 socket 。
--这可以用于你把 id 发送给其它服务，以转交 socket 的控制权。
-- 此函数作用为:调用此 socket 库的服务不再接收此id发过来的socket消息，需要做的是要尽快在别的服务调用 socket.start 以便能接受到数据
-- abandon use to forward socket id to other service
-- you must call socket.start(id) later in other service
function socket.abandon(id)
	local s = socket_pool[id]
	if s then
		driver.clear(s.buffer,buffer_pool)
		s.connected = false
		wakeup(s)
		socket_pool[id] = nil
	end
end
-- 设置缓冲区的大小，如果不设置，则缓冲区大小应该是不做限制的
function socket.limit(id, limit)
	local s = assert(socket_pool[id])
	s.buffer_limit = limit
end

---------------------- UDP ----------------------
--udp 协议不需要阻塞读取。这是因为 udp 是不可靠协议，无法预期下一个读到的数据包是什么（协议允许乱序和丢包）。
--udp 协议封装采用的是 callback 的方式。


local function create_udp_object(id, cb)
	assert(not socket_pool[id], "socket is not closed")
	socket_pool[id] = {
		id = id,
		connected = true,
		protocol = "UDP",
		callback = cb,
	}
end
--这个 API 创建一个 udp handle ，并给它绑定一个 callback 函数。
--当这个 handle 收到 udp 消息时，callback 函数将被触发。
--[[
socket.udp(function(str, from), address, port) : id

第一个参数是一个 callback 函数，它会收到两个参数。str 是一个字符串即收到的包内容，from 是一个表示消息来源的字符串用于返回这条消息（见 socket.sendto）。
第二个参数是一个字符串表示绑定的 ip 地址。如果你不写，默认为 ipv4 的 0.0.0.0 。
第三个参数是一个数字， 表示绑定的端口。如果不写或传 0 ，这表示仅创建一个 udp handle （用于发送），但不绑定固定端口。
这个函数会返回一个 handle id 。
]]
function socket.udp(callback, host, port)
	local id = driver.udp(host, port)
	create_udp_object(id, callback)
	return id
end
--[[
你可以给一个 udp handle 设置一个默认的发送目的地址。当你用 socket.udp 创建出一个非监听状态的 handle 时，
设置目的地址非常有用。因为你很难有别的方法获得一个有效的供 socket.sendto 使用的地址串。
这里 callback 是可选项，通常你应该在 socket.udp 创建出 handle 时就设置好 callback 函数。
但有时，handle 并不是当前 service 创建而是由别处创建出来的。
这种情况，你可以用 socket.start 重设 handle 的所有权，并用这个函数设置 callback 函数。
设置完默认的目的地址后，之后你就可以用 socket.write 来发送数据包。

注：handle 只能属于一个 service ，当一个 handle 归属一个 service 时，mtask 框架将对应的网络消息转发给它。
向一个 handle 发送网络数据包则不需要当前 service 拥有这个 handle 。
]]
function socket.udp_connect(id, addr, port, callback)
	local obj = socket_pool[id]
	if obj then
		assert(obj.protocol == "UDP")
		if callback then
			obj.callback = callback
		end
	else
		create_udp_object(id, callback)
	end
	driver.udp_connect(id, addr, port)
end
--[[
向一个网络地址发送一个数据包。
第二个参数 from 即是一个网络地址，这是一个 string ，通常由 callback 函数生成
，你无法自己构建一个地址串，但你可以把 callback 函数中得到的地址串保存起来以后使用。
发送的内容是一个字符串 data 。
]]
socket.sendto = assert(driver.udp_send)
--[[
这个字符串可以用 下面API 转换为可读的 ip 地址和端口，用于记录。
]]
socket.udp_address = assert(driver.udp_address)
--当 id 对应的 socket 上待发的数据超过 1M 字节后，系统将回调 callback 以示警告。
--function callback(id, size) 回调函数接收两个参数 id 和 size ，size 的单位是 K 。
--如果你不设回调，那么将每增加 64K 利用 mtask.error 写一行错误信息。
function socket.warning(id, callback)
	local obj = socket_pool[id]
	assert(obj)
	obj.on_warning = callback
end

return socket
