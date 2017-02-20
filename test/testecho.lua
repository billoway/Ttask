local mtask = require "mtask"

local mode = ...

if mode == "slave" then

mtask.start(function()
	mtask.dispatch("lua", function(_,_, ...)
		mtask.ret(mtask.pack(...))
	end)
end)

else

mtask.start(function()
	local slave = mtask.newservice(SERVICE_NAME, "slave")
	local n = 100000
	local start = mtask.now()
	print("call salve", n, "times in queue")
	for i=1,n do
		mtask.call(slave, "lua")
	end
	print("qps = ", n/ (mtask.now() - start) * 100)

	start = mtask.now()

	local worker = 10
	local task = n/worker
	print("call salve", n, "times in parallel, worker = ", worker)

	for i=1,worker do
		mtask.fork(function()
			for i=1,task do
				mtask.call(slave, "lua")
			end
			worker = worker -1
			if worker == 0 then
				print("qps = ", n/ (mtask.now() - start) * 100)
			end
		end)
	end
end)

end
