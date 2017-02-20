local mtask = require "mtask"
local sd = require "sharedata.corelib"

local service

mtask.init(function()
	service = mtask.uniqueservice "sharedatad"
end)

local sharedata = {}

local function monitor(name, obj, cobj)
	local newobj = cobj
	while true do
		newobj = mtask.call(service, "lua", "monitor", name, newobj)
		if newobj == nil then
			break
		end
		sd.update(obj, newobj)
	end
end

function sharedata.query(name)
	local obj = mtask.call(service, "lua", "query", name)
	local r = sd.box(obj)
	mtask.send(service, "lua", "confirm" , obj)
	mtask.fork(monitor,name, r, obj)
	return r
end

function sharedata.new(name, v)
	mtask.call(service, "lua", "new", name, v)
end

function sharedata.update(name, v)
	mtask.call(service, "lua", "update", name, v)
end

function sharedata.delete(name)
	mtask.call(service, "lua", "delete", name)
end

return sharedata
