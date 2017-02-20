local mtask = require "mtask"

local function timeout(t)
	print(t)
end

local function wakeup(co)
	for i=1,5 do
		mtask.sleep(50)
		mtask.wakeup(co)
	end
end

local function test()
	mtask.timeout(10, function() print("test timeout 10") end)
	for i=1,10 do
		print("test sleep",i,mtask.now())
		mtask.sleep(1)
	end
end

mtask.start(function()
	test()

	mtask.fork(wakeup, coroutine.running())
	mtask.timeout(300, function() timeout "Hello World" end)
	for i = 1, 10 do
		print(i, mtask.now())
		print(mtask.sleep(100))
	end
	mtask.exit()
	print("Test timer exit")

end)
