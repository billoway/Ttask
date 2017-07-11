local mtask = require "mtask"
local stm = require "mtask.stm"

local mode = ...

if mode == "slave" then

mtask.start(function()
	mtask.dispatch("lua", function (_,_, obj)
		local obj = stm.newcopy(obj)
		print("read:", obj(mtask.unpack))
		mtask.ret()
		mtask.error("sleep and read")
		for i=1,10 do
			mtask.sleep(10)
			print("read:", obj(mtask.unpack))
		end
		mtask.exit()
	end)
end)

else

mtask.start(function()
	local slave = mtask.newservice(SERVICE_NAME, "slave")
	local obj = stm.new(mtask.pack(1,2,3,4,5))
	local copy = stm.copy(obj)
	mtask.call(slave, "lua", copy)
	for i=1,5 do
		mtask.sleep(20)
		print("write", i)
		obj(mtask.pack("hello world", i))
	end
 	mtask.exit()
end)
end
