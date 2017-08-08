local mtask = require "mtask"
local debugchannel = require "mtask.debugchannel"

local CMD = {}

local channel

function CMD.start(address, fd)
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
	channel:write(cmdline)
end

function CMD.ping()
	mtask.ret()
end

mtask.start(function()
	mtask.dispatch("lua", function(_,_,cmd,...)
		local f = CMD[cmd]
		f(...)
	end)
end)
