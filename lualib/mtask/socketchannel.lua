local mtask = require "mtask"
local socket = require "mtask.socket"
local socketdriver = require "mtask.socketdriver"

-- channel support auto reconnect , and capture socket error in request/response transaction
-- { host = "", port = , auth = function(so) , response = function(so) session, data }

local socket_channel = {}
local channel = {}
local channel_socket = {}
local channel_meta = { __index = channel }
local channel_socket_meta = {
	__index = channel_socket,
	__gc = function(cs)
		local fd = cs[1]
		cs[1] = false
		if fd then
			socket.shutdown(fd)
		end
	end
}

local socket_error = setmetatable({}, {__tostring = function() return "[Error: socket]" end })	-- alias for error object
socket_channel.error = socket_error

function socket_channel.channel(desc)
	local c = {
		__host = assert(desc.host),-- ip地址
		__port = assert(desc.port),-- 端口
		__backup = desc.backup,-- 备用地址(成员需有一个或多个{host=xxx, port=xxx})
		__auth = desc.auth,	-- 认证函数
		__response = desc.response,	-- It's for session mode  如果是session模式，则需要提供此函数
		__request = {},	-- request seq { response func or session }	-- It's for order mode  消息处理函数，成员为函数
		__thread = {}, -- coroutine seq or session->coroutine map 存储等待回应的协程
		__result = {}, -- response result { coroutine -> result } 存储返回的结果，以便唤醒的时候能从对应的协程里面拿出
		__result_data = {}, --存储返回的结果，以便唤醒的时候能从对应的协程里面拿出
		__connecting = {}, -- 用于储存等待完成的队列，队列的成员为协程:co
		__sock = false,	-- 连接成功以后是一个 table，第一次元素为 fd，元表为 channel_socket_meta
		__closed = false,	-- 是否已经关闭
		__authcoroutine = false,-- 如果存在 __auth,那么这里存储的是认证过程的协程
		__nodelay = desc.nodelay, -- 配置是否启用 TCP 的 Nagle 算法
	}

	return setmetatable(c, channel_meta)
end

local function close_channel_socket(self)
	if self.__sock then
		local so = self.__sock
		self.__sock = false
		-- never raise error
		pcall(socket.close,so[1])
	end
end

local function wakeup_all(self, errmsg)
	if self.__response then
		for k,co in pairs(self.__thread) do
			self.__thread[k] = nil
			self.__result[co] = socket_error
			self.__result_data[co] = errmsg
			mtask.wakeup(co)
		end
	else
		for i = 1, #self.__request do
			self.__request[i] = nil
		end
		for i = 1, #self.__thread do
			local co = self.__thread[i]
			self.__thread[i] = nil
			if co then	-- ignore the close signal
				self.__result[co] = socket_error
				self.__result_data[co] = errmsg
				mtask.wakeup(co)
			end
		end
	end
end

local function exit_thread(self)
	local co = coroutine.running()
	if self.__dispatch_thread == co then
		self.__dispatch_thread = nil
		local connecting = self.__connecting_thread
		if connecting then
			mtask.wakeup(connecting)
		end
	end
end
-- session 模式下的
local function dispatch_by_session(self)
	local response = self.__response
	-- response() return session
	while self.__sock do
		local ok , session, result_ok, result_data, padding = pcall(response, self.__sock)
		if ok and session then
			local co = self.__thread[session]
			if co then
				if padding and result_ok then
					-- If padding is true, append result_data to a table (self.__result_data[co])
					local result = self.__result_data[co] or {}
					self.__result_data[co] = result
					table.insert(result, result_data)
				else
					self.__thread[session] = nil
					self.__result[co] = result_ok
					if result_ok and self.__result_data[co] then
						table.insert(self.__result_data[co], result_data)
					else
						self.__result_data[co] = result_data
					end
					mtask.wakeup(co)
				end
			else
				self.__thread[session] = nil
				mtask.error("socket: unknown session :", session)
			end
		else
			close_channel_socket(self)
			local errormsg
			if session ~= socket_error then
				errormsg = session
			end
			wakeup_all(self, errormsg)
		end
	end
	exit_thread(self)
end

local function pop_response(self)
	while true do
		local func,co = table.remove(self.__request, 1), table.remove(self.__thread, 1)
		if func then
			return func, co
		end
		self.__wait_response = coroutine.running()
		mtask.wait(self.__wait_response)
	end
end

local function push_response(self, response, co)
	if self.__response then
		-- response is session
		self.__thread[response] = co
	else
		-- response is a function, push it to __request
		table.insert(self.__request, response)
		table.insert(self.__thread, co)
		if self.__wait_response then
			mtask.wakeup(self.__wait_response)
			self.__wait_response = nil
		end
	end
end
-- 此函数由TCP保证时序，一个请求一个回应，相当于一个维护了一个请求队列，先到先处理，先返回
local function dispatch_by_order(self)
	while self.__sock do
		local func, co = pop_response(self)
		if not co then
			-- close signal
			wakeup_all(self, "channel_closed")
			break
		end
		local ok, result_ok, result_data, padding = pcall(func, self.__sock)
		if ok then
			if padding and result_ok then
				-- if padding is true, wait for next result_data
				-- self.__result_data[co] is a table
				local result = self.__result_data[co] or {}
				self.__result_data[co] = result
				table.insert(result, result_data)
			else
				self.__result[co] = result_ok
				if result_ok and self.__result_data[co] then
					table.insert(self.__result_data[co], result_data)
				else
					self.__result_data[co] = result_data
				end
				mtask.wakeup(co)
			end
		else
			close_channel_socket(self)
			local errmsg
			if result_ok ~= socket_error then
				errmsg = result_ok
			end
			self.__result[co] = socket_error
			self.__result_data[co] = errmsg
			mtask.wakeup(co)
			wakeup_all(self, errmsg)
		end
	end
	exit_thread(self)
end
-- 可以看作是 远端socket 的消息处理函数
local function dispatch_function(self)
	if self.__response then -- 如果 __response 存在，则是 session 模式
		return dispatch_by_session
	else
		return dispatch_by_order
	end
end

local function connect_backup(self)
	if self.__backup then
		for _, addr in ipairs(self.__backup) do
			local host, port
			if type(addr) == "table" then
				host, port = addr.host, addr.port
			else
				host = addr
				port = self.__port
			end
			mtask.error("socket: connect to backup host", host, port)
			local fd = socket.open(host, port)
			if fd then
				self.__host = host
				self.__port = port
				return fd
			end
		end
	end
end
-- 与远端建立连接
-- 如果连接不成功尝试备用地址
-- 设置消息处理函数
-- 如果存在 __auth 启用验证流程
local function connect_once(self)
	if self.__closed then
		return false
	end
	assert(not self.__sock and not self.__authcoroutine)
	local fd,err = socket.open(self.__host, self.__port)
	if not fd then -- 如果连接不成功，连接备用的地址
		fd = connect_backup(self)
		if not fd then
			return false, err
		end
	end
	if self.__nodelay then
		socketdriver.nodelay(fd)
	end

	self.__sock = setmetatable( {fd} , channel_socket_meta )
	self.__dispatch_thread = mtask.fork(dispatch_function(self), self)

	if self.__auth then
		self.__authcoroutine = coroutine.running()
		local ok , message = pcall(self.__auth, self)
		if not ok then
			close_channel_socket(self)
			if message ~= socket_error then
				self.__authcoroutine = false
				mtask.error("socket: auth failed", message)
			end
		end
		self.__authcoroutine = false
		if ok and not self.__sock then
			-- auth may change host, so connect again
			return connect_once(self)
		end
		return ok
	end

	return true
end
-- 尝试连接，如果没有明确指定只连接一次，那么一直尝试重连
local function try_connect(self , once)
	local t = 0
	while not self.__closed do
		local ok, err = connect_once(self)
		if ok then
			if not once then
				mtask.error("socket: connect to", self.__host, self.__port)
			end
			return
		elseif once then
			return err
		else
			mtask.error("socket: connect", err)
		end
		-- 如果 once 不为真，则一直尝试连接
		if t > 1000 then 
			mtask.error("socket: try to reconnect", self.__host, self.__port)
			mtask.sleep(t)
			t = 0
		else
			mtask.sleep(t)
		end
		t = t + 100
	end
end
-- 检查是不是已经连接上了，如果返回nil则代表没有连接上
local function check_connection(self)
	if self.__sock then
		if socket.disconnected(self.__sock[1]) do
			--closed by peer
			mtask.error("socket: disconnect detected ", self.__host, self.__port)
			close_channel_socket(self)
			return
		end

		local authco = self.__authcoroutine
		if not authco then
			return true
		end
		if authco == coroutine.running() then
			-- authing
			return true
		end
	end
	if self.__closed then
		return false
	end
end
-- 阻塞的连接(阻塞的只是一个协程)
local function block_connect(self, once)
	local r = check_connection(self)
	if r ~= nil then
		return r
	end
	local err
	-- 如果正在等待连接完成的队列大于0，则将当前协程加入队列
	if #self.__connecting > 0 then
		-- connecting in other coroutine
		local co = coroutine.running()
		table.insert(self.__connecting, co)
		mtask.wait(co)
	else -- 尝试连接，如果连接成功，依次唤醒等待连接完成的队列
		self.__connecting[1] = true
		err = try_connect(self, once)
		self.__connecting[1] = nil
		for i=2, #self.__connecting do
			local co = self.__connecting[i]
			self.__connecting[i] = nil
			mtask.wakeup(co)
		end
	end

	r = check_connection(self)
	if r == nil then
		mtask.error(string.format("Connect to %s:%d failed (%s)", self.__host, self.__port, err))
		error(socket_error)
	else
		return r
	end
end
-- 这里的 once 如果为真就只取连接一次(不管失败还是成功都只尝试一次连接)， 如果不为真就一直尝试连接
function channel:connect(once)
	if self.__closed then
		if self.__dispatch_thread then
			-- closing, wait
			assert(self.__connecting_thread == nil, "already connecting")
			local co = coroutine.running()
			self.__connecting_thread = co
			mtask.wait(co)
			self.__connecting_thread = nil
		end
		self.__closed = false
	end

	return block_connect(self, once)
end

local function wait_for_response(self, response)
	local co = coroutine.running()
	push_response(self, response, co)
	mtask.wait(co)

	local result = self.__result[co]
	self.__result[co] = nil
	local result_data = self.__result_data[co]
	self.__result_data[co] = nil

	if result == socket_error then
		if result_data then
			error(result_data)
		else
			error(socket_error)
		end
	else
		assert(result, result_data)
		return result_data
	end
end

local socket_write = socket.write
local socket_lwrite = socket.lwrite

local function sock_err(self)
	close_channel_socket(self)
	wakeup_all(self)
	error(socket_error)
end
-- 向远端发送一个请求包，如果 response 为空，则单向请求，不需要一个接收包
function channel:request(request, response, padding)
	assert(block_connect(self, true))	-- connect once
	local fd = self.__sock[1]

	if padding then
		-- padding may be a table, to support multi part request
		-- multi part request use low priority socket write
		-- now socket_lwrite returns as socket_write
		if not socket_lwrite(fd , request) then
			sock_err(self)
		end
		for _,v in ipairs(padding) do
			if not socket_lwrite(fd, v) then
				sock_err(self)
			end
		end
	else
		if not socket_write(fd , request) then
			sock_err(self)
		end
	end

	if response == nil then
		-- no response
		return
	end

	return wait_for_response(self, response)
end
-- 阻塞的接收一个包
-- channel:request(req)
-- local resp = channel:response(dispatch)
-- 等价于local resp = channel:request(req, dispatch)
function channel:response(response)
	assert(block_connect(self))

	return wait_for_response(self, response)
end

function channel:close()
	if not self.__closed then
		local thread = self.__dispatch_thread
		self.__closed = true
		close_channel_socket(self)
		if not self.__response and self.__dispatch_thread == thread and thread then
			-- dispatch by order, send close signal to dispatch thread
			push_response(self, true, false)	-- (true, false) is close signal
		end
	end
end

function channel:changehost(host, port)
	self.__host = host
	if port then
		self.__port = port
	end
	if not self.__closed then
		close_channel_socket(self)
	end
end
-- 更改备用地址
function channel:changebackup(backup)
	self.__backup = backup
end

channel_meta.__gc = channel.close

local function wrapper_socket_function(f)
	return function(self, ...)
		local result = f(self[1], ...)
		if not result then
			error(socket_error)
		else
			return result
		end
	end
end

channel_socket.read = wrapper_socket_function(socket.read)
channel_socket.readline = wrapper_socket_function(socket.readline)

return socket_channel
