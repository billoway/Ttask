local mtask = require "mtask"

local mode = ...

if mode == "TICK" then
-- this service whould response the request every 1s.

local response_queue = {}

local function response()
	while true do
		mtask.sleep(100)	-- sleep 1s
		for k,v in ipairs(response_queue) do
			v(true, mtask.now())		-- true means succ, false means error
			response_queue[k] = nil
		end
	end
end

mtask.start(function()
	mtask.fork(response)
	mtask.dispatch("lua", function()
		table.insert(response_queue, mtask.response())
	end)
end)

else

local function request(tick, i)
	print(i, "call", mtask.now())
	print(i, "response", mtask.call(tick, "lua"))
	print(i, "end", mtask.now())
end

mtask.start(function()
	local tick = mtask.newservice(SERVICE_NAME, "TICK")

	for i=1,5 do
		mtask.fork(request, tick, i)
		mtask.sleep(10)
	end
end)

end
