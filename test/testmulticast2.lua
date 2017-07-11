local mtask = require "mtask"
local dc = require "mtask.datacenter"
local mc = require "mtask.multicast"

mtask.start(function()
	print("remote start")
	local console = mtask.newservice("console")
	local channel = dc.get "MCCHANNEL"
	if channel then
		print("remote channel", channel)
	else
		print("create local channel")
	end
	for i=1,10 do
		local sub = mtask.newservice("testmulticast", "sub")
		mtask.call(sub, "lua", "init", channel)
	end
	local c = mc.new {
		channel = channel ,
		dispatch = function(...) print("======>", ...) end,
	}
	c:subscribe()
	c:publish("Remote message")
	c:unsubscribe()
	c:publish("Remote message2")
	c:delete()
	mtask.exit()
end)
