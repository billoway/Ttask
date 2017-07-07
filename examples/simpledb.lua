local mtask = require "mtask"
require "mtask.manager"	-- import mtask.register
local db = {}

local command = {}

function command.GET(key)
	return db[key]
end

function command.SET(key, value)
	local last = db[key]
	db[key] = value
	return last
end

mtask.start(function()
	mtask.dispatch("lua", function(session, address, cmd, ...)
		cmd = cmd:upper()
		if cmd == "PING" then
			assert(session == 0)
			local str = (...)
			if #str > 20 then
				str = str:sub(1,20) .. "...(" .. #str .. ")"
			end
			mtask.error(string.format("%s ping %s", mtask.address(address), str))
			return
		end
		local f = command[cmd]
		if f then
			mtask.ret(mtask.pack(f(...)))
		else
			error(string.format("Unknown command %s", tostring(cmd)))
		end
	end)
	mtask.register "SIMPLEDB"
end)
