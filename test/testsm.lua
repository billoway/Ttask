local mtask = require "mtask"
local sharemap = require "mtask.sharemap"

local mode = ...

if mode == "slave" then
--slave

local function dump(reader)
	reader:update()
	print("x=", reader.x)
	print("y=", reader.y)
	print("s=", reader.s)
end

mtask.start(function()
	local reader
	mtask.dispatch("lua", function(_,_,cmd,...)
		if cmd == "init" then
			reader = sharemap.reader(...)
		else
			assert(cmd == "ping")
			dump(reader)
		end
		mtask.ret()
	end)
end)

else
-- master
mtask.start(function()
	-- register share type schema
	sharemap.register("./test/sharemap.sp")
	local slave = mtask.newservice(SERVICE_NAME, "slave")
	local writer = sharemap.writer("foobar", { x=0,y=0,s="hello" })
	mtask.call(slave, "lua", "init", "foobar", writer:copy())
	writer.x = 1
	writer:commit()
	mtask.call(slave, "lua", "ping")
	writer.y = 2
	writer:commit()
	mtask.call(slave, "lua", "ping")
	writer.s = "world"
	writer:commit()
	mtask.call(slave, "lua", "ping")
end)

end
