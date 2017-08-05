local mtask = require "mtask"
local netpack = require "mtask.netpack"
local socketdriver = require "mtask.socketdriver"

local gateserver = {}

local socket	-- listen socket
local queue		-- message queue
local maxclient	-- max client
local client_number = 0
local CMD = setmetatable({}, { __gc = function() netpack.clear(queue) end })
local nodelay = false

local connection = {}

function gateserver.openclient(fd)
	mtask.error("gateserver.lua gateserver.openclient",fd)
	if connection[fd] then
		socketdriver.start(fd)
	end
end

function gateserver.closeclient(fd)
	mtask.error("gateserver.lua gateserver.closeclient")
	local c = connection[fd]
	if c then
		connection[fd] = false
		socketdriver.close(fd)
	end
end

function gateserver.start(handler)
	mtask.error("gateserver.lua gateserver.start %s",handler)
	assert(handler.message)
	assert(handler.connect)

	function CMD.open( source, conf )
		mtask.error("gateserver.lua CMD.open")
		assert(not socket)
		local address = conf.address or "0.0.0.0"
		local port = assert(conf.port)
		maxclient = conf.maxclient or 1024
		nodelay = conf.nodelay
		mtask.error(string.format("Listen on %s:%d", address, port))
		socket = socketdriver.listen(address, port)
		socketdriver.start(socket)
		if handler.open then
			return handler.open(source, conf)
		end
	end

	function CMD.close()
		mtask.error("gateserver.lua CMD.close")
		assert(socket)
		socketdriver.close(socket)
	end

	local MSG = {}

	local function dispatch_msg(fd, msg, sz)
		mtask.error("gateserver.lua  dispatch_msg",fd)
		if connection[fd] then
			handler.message(fd, msg, sz)
		else
			mtask.error(string.format("Drop message from fd (%d) : %s", fd, netpack.tostring(msg,sz)))
		end
	end

	MSG.data = dispatch_msg

	local function dispatch_queue()
		mtask.error("gateserver.lua  dispatch_queue")
		local fd, msg, sz = netpack.pop(queue)
		if fd then
			-- may dispatch even the handler.message blocked
			-- If the handler.message never block, the queue should be empty, so only fork once and then exit.
			mtask.fork(dispatch_queue)
			dispatch_msg(fd, msg, sz)

			for fd, msg, sz in netpack.pop, queue do
				dispatch_msg(fd, msg, sz)
			end
		end
	end

	MSG.more = dispatch_queue

	function MSG.open(fd, msg)
		mtask.error("gateserver.lua  MSG.open")
		if client_number >= maxclient then
			socketdriver.close(fd)
			return
		end
		if nodelay then
			socketdriver.nodelay(fd) --会向底层的管道发送一个"T"的消息
		end
		connection[fd] = true
		client_number = client_number + 1
		handler.connect(fd, msg)
	end

	local function close_fd(fd)
		local c = connection[fd]
		if c ~= nil then
			connection[fd] = nil
			client_number = client_number - 1
		end
	end

	function MSG.close(fd)
		mtask.error("gateserver.lua  MSG.close")
		if fd ~= socket then
			if handler.disconnect then
				handler.disconnect(fd)
			end
			close_fd(fd)
		else
			socket = nil
		end
	end

	function MSG.error(fd, msg)
		mtask.error("gateserver.lua  MSG.error")
		if fd == socket then
			socketdriver.close(fd)
			mtask.error("gateserver close listen socket, accpet error:",msg)
		else
			if handler.error then
				handler.error(fd, msg)
			end
			close_fd(fd)
		end
	end

	function MSG.warning(fd, size)
		mtask.error("gateserver.lua  MSG.warning")
		if handler.warning then
			handler.warning(fd, size)
		end
	end

	mtask.register_protocol {
		name = "socket",
		id = mtask.PTYPE_SOCKET,	-- PTYPE_SOCKET = 6
		unpack = function ( msg, sz )
			return netpack.filter( queue, msg, sz)
		end,
		dispatch = function (_, _, q, type, ...)
			queue = q
			if type then
				MSG[type](...)
			end
		end
	}

	mtask.start(function()
		mtask.error("gateserver.lua  start")
		mtask.dispatch("lua", function (_, address, cmd, ...)
			mtask.error(string.format("gateserver.lua  dispatch %s %s",address,cmd))
			local f = CMD[cmd]
			print(f)
			if f then
				mtask.ret(mtask.pack(f(address, ...)))
			else
				mtask.ret(mtask.pack(handler.command(cmd, address, ...)))
			end
		end)
		mtask.error("gateserver.lua  booted")
	end)
end

return gateserver
