local mtask = require "mtask"
local debugchannel = require "mtask.debugchannel"

local CMD = {}

local channel

function CMD.start(address, fd)
	mtask.error("debug_agent.lua CMD.start")
	assert(channel == nil, "start more than once")
	mtask.error(string.format("Attach to :%08x", address))
	local handle
	channel, handle = debugchannel.create()
	local ok, err = pcall(mtask.call, address, "debug", "REMOTEDEBUG", fd, handle)
	if not ok then
		mtask.ret(mtask.pack(false, "Debugger attach failed"))
	else
		-- todo hook
		mtask.ret(mtask.pack(true))
	end
	mtask.exit()
end

function CMD.cmd(cmdline)
	mtask.error("debug_agent.lua CMD.cmd")
	channel:write(cmdline)
end

function CMD.ping()
	mtask.error("debug_agent.lua CMD.ping")
	mtask.ret()
end

mtask.start(function()
	mtask.error("debug_agent.lua start")
	mtask.dispatch("lua", function(_,_,cmd,...)
		mtask.error("debug_agent.lua dispatch %s",cmd)
		local f = CMD[cmd]
		f(...)
	end)
		mtask.error("debug_agent.lua booted")
end)
