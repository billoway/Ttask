local mtask = require "mtask"
require "mtask.manager"	-- import mtask.register
local db = {}

local command = {}

function command.GET(key)
	print("watchdog.lua command.GET".." key=>"..key)
	return db[key]
end

function command.SET(key, value)
	print("watchdog.lua command.SET".." key=>"..key.." value=>"..value)
	local last = db[key]
	db[key] = value
	return last
end

mtask.start(function()
	print("simpledb.lua start calling")
	mtask.dispatch("lua", function(session, address, cmd, ...)
		print("watchdog.lua ".."cmd==>"..cmd.."  session==>"..session.."  address==>"..string.format("[%x]",address))
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
