local mtask = require "mtask"
local sprotoloader = require "sprotoloader"

local max_client = 64

mtask.start(function()
	print("Server start")
	mtask.uniqueservice("protoloader")
	local console = mtask.newservice("console")
	mtask.newservice("debug_console",8000)
	mtask.newservice("simpledb")
	local watchdog = mtask.newservice("watchdog")
	mtask.call(watchdog, "lua", "start", {
		port = 8888,
		maxclient = max_client,
		nodelay = true,
	})
	print("Watchdog listen on ", 8888)

	mtask.exit()
end)
