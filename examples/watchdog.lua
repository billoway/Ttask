local mtask = require "mtask"

local CMD = {}
local SOCKET = {}
local gate
local agent = {}

function SOCKET.open(fd, addr)
	mtask.error("New client from : " .. addr)
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
	print("socket close",fd)
	close_agent(fd)
end

function SOCKET.error(fd, msg)
	print("socket error",fd, msg)
	close_agent(fd)
end

function SOCKET.warning(fd, size)
	-- size K bytes havn't send out in fd
	print("socket warning", fd, size)
end

function SOCKET.data(fd, msg)
end

function CMD.start(conf)
	mtask.call(gate, "lua", "open" , conf)
end

function CMD.close(fd)
	close_agent(fd)
end

mtask.start(function()
	mtask.dispatch("lua", function(session, source, cmd, subcmd, ...)
		if cmd == "socket" then
			local f = SOCKET[subcmd]
			f(...)
			-- socket api don't need return
		else
			local f = assert(CMD[cmd])
			mtask.ret(mtask.pack(f(subcmd, ...)))
		end
	end)

	gate = mtask.newservice("gate")
end)
