local mtask = require "mtask"
local service = require "mtask.service"

local kvdb = {}

function kvdb.get(db,key)
	return mtask.call(service.query(db), "lua", "get", key)
end

function kvdb.set(db,key, value)
	mtask.call(service.query(db), "lua", "set", key , value)
end

-- this function will be injected into an unique service, so don't refer any upvalues
local function service_mainfunc(...)
	local mtask = require "mtask"

	mtask.error(...)	-- (...) passed from service.new

	local db = {}

	local command = {}

	function command.get(key)
		return db[key]
	end

	function command.set(key, value)
		db[key] = value
	end

	-- mtask.start is compatible
	mtask.dispatch("lua", function(session, address, cmd, ...)
		mtask.ret(mtask.pack(command[cmd](...)))
	end)
end

function kvdb.new(db)
	return service.new(db, service_mainfunc, "Service Init")
end

return kvdb
