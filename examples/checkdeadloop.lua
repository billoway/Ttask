local mtask = require "mtask"

local list = {}

local function timeout_check(ti)
	if not next(list) then
		return
	end
	mtask.sleep(ti)	-- sleep 10 sec
	for k,v in pairs(list) do
		mtask.error("timout",ti,k,v)
	end
end

mtask.start(function()
	mtask.error("ping all")
	local list_ret = mtask.call(".launcher", "lua", "LIST")
	for addr, desc in pairs(list_ret) do
		list[addr] = desc
		mtask.fork(function()
			mtask.call(addr,"debug","INFO")
			list[addr] = nil
		end)
	end
	mtask.sleep(0)
	timeout_check(100)
	timeout_check(400)
	timeout_check(500)
	mtask.exit()
end)
