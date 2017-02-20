local mtask = require "mtask"

local mode = ...

if mode == "slave" then

local CMD = {}

function CMD.sum(n)
	mtask.error("for loop begin")
	local s = 0
	for i = 1, n do
		s = s + i
	end
	mtask.error("for loop end")
end

function CMD.blackhole()
end

mtask.start(function()
	mtask.dispatch("lua", function(_,_, cmd, ...)
		local f = CMD[cmd]
		f(...)
	end)
end)

else

mtask.start(function()
	local slave = mtask.newservice(SERVICE_NAME, "slave")
	for step = 1, 20 do
		mtask.error("overload test ".. step)
		for i = 1, 512 * step do
			mtask.send(slave, "lua", "blackhole")
		end
		mtask.sleep(step)
	end
	local n = 1000000000
	mtask.error(string.format("endless test n=%d", n))
	mtask.send(slave, "lua", "sum", n)
end)

end
