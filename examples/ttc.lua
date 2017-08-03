local mtask = require "mtask"
local sprotoloader = require "sprotoloader"

local max_client = 64

mtask.start(function()
    local test = mtask.newservice("test")
    mtask.call(test,"lua","start","P2")
--[[
    local s1 = mtask.call(test,"lua","start","P1")
    print("ttc.lua session1=>",s1)
    local s3 = mtask.call(test,"lua","start","P3")
    print("ttc.lua session3=>",s3)
--]]
       

end)

--[[
mtask.start(function()
	print("\n**************************************************")
	print("Myself custom project TTc.lua Server start calling")
	print("**************************************************\n")
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
--]]
