local mtask = require "mtask"
local CMD = {}
local SOCKET = {}
local gate
local agent = {}

function SOCKET.open(fd, addr)
	print("New client from : " .. addr)
	print("watchdog.lua SOCKET.open calling".."fd==>"..fd)
	agent[fd] = mtask.newservice("agent")
	mtask.call(agent[fd], "lua", "start", { gate = gate, client = fd, watchdog = mtask.self() })
end

local function close_agent(fd)
	print("watchdog.lua close_agent calling".."fd==>"..fd)
	local a = agent[fd]
	agent[fd] = nil
	if a then
		mtask.call(gate, "lua", "kick", fd)
		-- disconnect never return
		mtask.send(a, "lua", "disconnect")
	end
end

function SOCKET.close(fd)
	print("watchdog.lua SOCKET.close calling".."fd==>"..fd)
	print("socket close",fd)
	close_agent(fd)
end

function SOCKET.error(fd, msg)
	print("watchdog.lua SOCKET.error calling".."fd==>"..fd)
	close_agent(fd)
end

function SOCKET.warning(fd, size)
	print("watchdog.lua SOCKET.warning calling".."fd==>"..fd)
	-- size K bytes havn't send out in fd
	print("socket warning", fd, size)
end

function SOCKET.data(fd, msg)
end

function CMD.start(conf)
	print("watchdog.lua CMD.start calling")
	mtask.call(gate, "lua", "open" , conf)
end

function CMD.close(fd)
	print("watchdog.lua CMD.close calling".."fd==>"..fd)
	close_agent(fd)
end

mtask.start(function()
	print("watchdog.lua start calling")
	mtask.dispatch("lua", function(session, source, cmd, subcmd, ...)
		print("watchdog.lua ".."cmd==>"..cmd.."  session==>"..session.."  source==>"..string.format("[%x]",source))
		if type(subcmd) == "table" then
			mtask.print(subcmd)
		end

		if cmd == "socket" then
			local f = SOCKET[subcmd]
			f(...)
			-- socket api don't need return
		else
			local f = assert(CMD[cmd])
			mtask.ret(mtask.pack(f(subcmd, ...)))
		end
	end)
	print("watchdog.lua end calling")
	gate = mtask.newservice("gate")
end)
