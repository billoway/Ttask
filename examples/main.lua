local mtask = require "mtask"
local sprotoloader = require "sprotoloader"

local max_client = 64

mtask.start(function()
	print("**************************************************")
	print("\t My service starting")
	print("**************************************************")
	mtask.uniqueservice("protoloader")
	if not mtask.getenv "daemon" then
		local console = mtask.newservice("console")
	end
	mtask.newservice("debug_console",8000)
	mtask.newservice("simpledb")
	local watchdog = mtask.newservice("watchdog")
	mtask.call(watchdog, "lua", "start", {
		port = 8888,
		maxclient = max_client,
		nodelay = true,
	})
	mtask.error("Watchdog listen on", 8888)
	mtask.exit()
end)
