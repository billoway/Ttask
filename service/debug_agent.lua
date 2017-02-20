local mtask = require "mtask"
local debugchannel = require "debugchannel"

local CMD = {}

local channel

function CMD.start(address, fd)
	assert(channel == nil, "start more than once")
	mtask.error(string.format("Attach to :%08x", address))
	local handle
	channel, handle = debugchannel.create()
	mtask.call(address, "debug", "REMOTEDEBUG", fd, handle)
	-- todo hook
	mtask.ret(mtask.pack(nil))
	mtask.exit()
end

function CMD.cmd(cmdline)
	channel:write(cmdline)
end

mtask.start(function()
	mtask.dispatch("lua", function(_,_,cmd,...)
		local f = CMD[cmd]
		f(...)
	end)
end)
