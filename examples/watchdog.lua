local mtask = require "mtask"
local CMD = {}
local SOCKET = {}
local gate
local agent = {}

function SOCKET.open(fd, addr)
	mtask.error(string.format("watchdog.lua SOCKET.open  %s New client from :%s",fd,addr))
	agent[fd] = mtask.newservice("agent")
	mtask.call(agent[fd], "lua", "start", { gate = gate, client = fd, watchdog = mtask.self() })
end

local function close_agent(fd)
	local a = agent[fd]
	agent[fd] = nil
	if a then
		mtask.call(gate, "lua", "kick", fd)
		-- disconnect never return
		mtask.send(a, "lua", "disconnect")
	end
end

function SOCKET.close(fd)
	mtask.error(string.format("watchdog.lua SOCKET.close %s",fd))
	close_agent(fd)
end

function SOCKET.error(fd, msg)
	mtask.error(string.format("watchdog.lua SOCKET.data %s %s",fd,#msg))
	close_agent(fd)
end

function SOCKET.warning(fd, size)
	-- size K bytes havn't send out in fd
	mtask.error(string.format("watchdog.lua SOCKET.warning %s %s",fd,size))
end

function SOCKET.data(fd, msg)
	mtask.error(string.format("watchdog.lua SOCKET.data %s %s",fd,#msg))
end

function CMD.start(conf)
	mtask.error(string.format("watchdog.lua CMD.start %s",conf))
	mtask.call(gate, "lua", "open" , conf)
end

function CMD.close(fd)
	mtask.error(string.format("watchdog.lua CMD.close %s",fd))
	close_agent(fd)
end

mtask.start(function()
	mtask.error("watchdog.lua start")
	mtask.dispatch("lua", function(session, source, cmd, subcmd, ...)
	    mtask.error(string.format("watchdog.lua dispatch %s %s %s %s",session,source,cmd,subcmd))
		if cmd == "socket" then
			local f = SOCKET[subcmd]
			f(...)
			-- socket api don't need return
		else
			local f = assert(CMD[cmd])
			mtask.ret(mtask.pack(f(subcmd, ...)))
		end
	end)
	mtask.error("watchdog.lua booted")
	gate = mtask.newservice("gate")
end)
