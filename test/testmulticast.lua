local mtask = require "mtask"
local mc = require "mtask.multicast"
local dc = require "mtask.datacenter"

local mode = ...

if mode == "sub" then

mtask.start(function()
	mtask.dispatch("lua", function (_,_, cmd, channel)
		assert(cmd == "init")
		local c = mc.new {
			channel = channel ,
			dispatch = function (channel, source, ...)
				print(string.format("%s <=== %s %s",mtask.address(mtask.self()),mtask.address(source), channel), ...)
			end
		}
		print(mtask.address(mtask.self()), "sub", c)
		c:subscribe()
		mtask.ret(mtask.pack())
	end)
end)

else

mtask.start(function()
	local channel = mc.new()
	print("New channel", channel)
	for i=1,10 do
		local sub = mtask.newservice(SERVICE_NAME, "sub")
		mtask.call(sub, "lua", "init", channel.channel)
	end

	dc.set("MCCHANNEL", channel.channel)	-- for multi node test

	print(mtask.address(mtask.self()), "===>", channel)
	channel:publish("Hello World")
end)

end
