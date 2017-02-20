local mtask = require "mtask"

local function term()
	mtask.error("Sleep one second, and term the call to UNEXIST")
	mtask.sleep(100)
	local self = mtask.self()
	mtask.send(mtask.self(), "debug", "TERM", "UNEXIST")
end

mtask.start(function()
	mtask.fork(term)
	mtask.error("call an unexist named service UNEXIST, may block")
	pcall(mtask.call, "UNEXIST", "lua", "test")
	mtask.error("unblock the unexisted service call")
end)
