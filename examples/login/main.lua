local mtask = require "mtask"

mtask.start(function()
	local loginserver = mtask.newservice("logind")
	local gate = mtask.newservice("gated", loginserver)

	mtask.call(gate, "lua", "open" , {
		port = 8888,
		maxclient = 64,
		servername = "sample",
	})
end)
