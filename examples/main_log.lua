local mtask = require "mtask"
local harbor = require "mtask.harbor"
require "mtask.manager"	-- import mtask.monitor

local function monitor_master()
	harbor.linkmaster()
	print("master is down")
	mtask.exit()
end

mtask.start(function()
	print("Log server start")
	mtask.monitor "simplemonitor"
	local log = mtask.newservice("globallog")
	mtask.fork(monitor_master)
end)

