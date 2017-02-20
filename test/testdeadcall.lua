local mtask = require "mtask"

local mode = ...

if mode == "test" then

mtask.start(function()
	mtask.dispatch("lua", function (...)
		print("====>", ...)
		mtask.exit()
	end)
end)

elseif mode == "dead" then

mtask.start(function()
	mtask.dispatch("lua", function (...)
		mtask.sleep(100)
		print("return", mtask.ret "")
	end)
end)

else

	mtask.start(function()
		local test = mtask.newservice(SERVICE_NAME, "test")	-- launch self in test mode

		print(pcall(function()
			mtask.call(test,"lua", "dead call")
		end))

		local dead = mtask.newservice(SERVICE_NAME, "dead")	-- launch self in dead mode

		mtask.timeout(0, mtask.exit)	-- exit after a while, so the call never return
		mtask.call(dead, "lua", "whould not return")
	end)
end
