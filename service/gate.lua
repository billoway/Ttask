local mtask = require "mtask"
local gateserver = require "snax.gateserver"
local netpack = require "mtask.netpack"

local watchdog
local connection = {}	-- fd -> connection : { fd , client, agent , ip, mode }
local forwarding = {}	-- agent -> connection

mtask.register_protocol {
	name = "client",
	id = mtask.PTYPE_CLIENT,
}

local handler = {}

function handler.open(source, conf)
	mtask.error(string.format("gate.lua handler.open source=>%s %s",source,conf))
	watchdog = conf.watchdog or source
end

function handler.message(fd, msg, sz)
	mtask.error(string.format("gate.lua handler.message fd=>%s %s %s",fd,#msg,sz))
	-- recv a package, forward it
	local c = connection[fd]
	local agent = c.agent
	if agent then
		mtask.redirect(agent, c.client, "client", 1, msg, sz)
	else
		mtask.send(watchdog, "lua", "socket", "data", fd, netpack.tostring(msg, sz))
	end
end

function handler.connect(fd, addr)
	mtask.error(string.format("gate.lua handler.connect fd=>%s addr=>%s",fd,addr))
	local c = {
		fd = fd,
		ip = addr,
	}
	connection[fd] = c
	mtask.send(watchdog, "lua", "socket", "open", fd, addr)
end

local function unforward(c)
	if c.agent then
		forwarding[c.agent] = nil
		c.agent = nil
		c.client = nil
	end
end

local function close_fd(fd)
	local c = connection[fd]
	if c then
		unforward(c)
		connection[fd] = nil
	end
end

function handler.disconnect(fd)
	mtask.error(string.format("gate.lua handler.disconnect fd=>%s",fd))
	close_fd(fd)
	mtask.send(watchdog, "lua", "socket", "close", fd)
end

function handler.error(fd, msg)
	mtask.error(string.format("gate.lua handler.error fd=>%s msg=>%s",fd,#msg))
	close_fd(fd)
	mtask.send(watchdog, "lua", "socket", "error", fd, msg)
end

function handler.warning(fd, size)
	mtask.error(string.format("gate.lua handler.warning fd=>%s size=>%s",fd,size))
	mtask.send(watchdog, "lua", "socket", "warning", fd, size)
end

local CMD = {}

function CMD.forward(source, fd, client, address)
	mtask.error(string.format("gate.lua CMD.forward source=>%s fd=>%s client=>%s address=>%s",source,fd,client,address))
	local c = assert(connection[fd])
	unforward(c)
	c.client = client or 0
	c.agent = address or source
	forwarding[c.agent] = c
	gateserver.openclient(fd)
end

function CMD.accept(source, fd)
	mtask.error(string.format("gate.lua CMD.accept source=>%s fd=>%s",source,fd))
	local c = assert(connection[fd])
	unforward(c)
	gateserver.openclient(fd)
end

function CMD.kick(source, fd)
	mtask.error(string.format("gate.lua CMD.kick source=>%s fd=>%s",source,fd))
	gateserver.closeclient(fd)
end

function handler.command(cmd, source, ...)
	mtask.error(string.format("gate.lua handler.command cmd=>%s source=>%s",cmd,source))
	local f = assert(CMD[cmd])
	return f(source, ...)
end

gateserver.start(handler)
