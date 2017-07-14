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
	print("gate.lua handler.open calling".." source=>"..string.format("[%x]",source))
	watchdog = conf.watchdog or source
end

function handler.message(fd, msg, sz)
	print("gate.lua handler.message calling".." fd=>"..fd.." sz=>"..sz)
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
	print("gate.lua handler.connect calling".." fd=>"..fd)
	local c = {
		fd = fd,
		ip = addr,
	}
	connection[fd] = c
	mtask.send(watchdog, "lua", "socket", "open", fd, addr)
end

local function unforward(c)
	print("gate.lua unforward calling")
	if c.agent then
		forwarding[c.agent] = nil
		c.agent = nil
		c.client = nil
	end
end

local function close_fd(fd)
	print("gate.lua close_fd calling".." fd=>"..fd)
	local c = connection[fd]
	if c then
		unforward(c)
		connection[fd] = nil
	end
end

function handler.disconnect(fd)
	print("gate.lua handler.disconnect calling".." fd=>"..fd)
	close_fd(fd)
	mtask.send(watchdog, "lua", "socket", "close", fd)
end

function handler.error(fd, msg)
	print("gate.lua handler.error calling".." fd=>"..fd)
	close_fd(fd)
	mtask.send(watchdog, "lua", "socket", "error", fd, msg)
end

function handler.warning(fd, size)
	print("gate.lua handler.warning calling".." fd=>"..fd.." size=>"..size)
	mtask.send(watchdog, "lua", "socket", "warning", fd, size)
end

local CMD = {}

function CMD.forward(source, fd, client, address)
	print("gate.lua CMD.forward calling".." source=>"..string.format("[%x]",source))
	local c = assert(connection[fd])
	unforward(c)
	c.client = client or 0
	c.agent = address or source
	forwarding[c.agent] = c
	gateserver.openclient(fd)
end

function CMD.accept(source, fd)
	print("gate.lua CMD.accept calling".." source=>"..string.format("[%x]",source))
	local c = assert(connection[fd])
	unforward(c)
	gateserver.openclient(fd)
end

function CMD.kick(source, fd)
	print("gate.lua CMD.kick calling".." source=>"..string.format("[%x]",source))
	gateserver.closeclient(fd)
end

function handler.command(cmd, source, ...)
	print("gate.lua handler.command calling".." cmd=>"..cmd.." source"..string.format("[%x]",source))
	local f = assert(CMD[cmd])
	return f(source, ...)
end

gateserver.start(handler)
print("gate.lua calling gateserver.start")
