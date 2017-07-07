local mtask = require "mtask"
local sd = require "mtask.sharedata.corelib"

local service

mtask.init(function()
	service = mtask.uniqueservice "sharedatad"
end)

local sharedata = {}
local cache = setmetatable({}, { __mode = "kv" })

local function monitor(name, obj, cobj)
	local newobj = cobj
	while true do
		newobj = mtask.call(service, "lua", "monitor", name, newobj)
		if newobj == nil then
			break
		end
		sd.update(obj, newobj)
	end
	if cache[name] == obj then
		cache[name] = nil
	end
end

function sharedata.query(name)
	if cache[name] then
		return cache[name]
	end
	local obj = mtask.call(service, "lua", "query", name)
	local r = sd.box(obj)
	mtask.send(service, "lua", "confirm" , obj)
	mtask.fork(monitor,name, r, obj)
	cache[name] = r
	return r
end

function sharedata.new(name, v, ...)
	mtask.call(service, "lua", "new", name, v, ...)
end

function sharedata.update(name, v, ...)
	mtask.call(service, "lua", "update", name, v, ...)
end

function sharedata.delete(name)
	mtask.call(service, "lua", "delete", name)
end

function sharedata.flush()
	for name, obj in pairs(cache) do
		sd.flush(obj)
	end
	collectgarbage()
end

function sharedata.deepcopy(name, ...)
	if cache[name] then
		local cobj = cache[name].__obj
		return sd.copy(cobj, ...)
	end

	local cobj = mtask.call(service, "lua", "query", name)
	local ret = sd.copy(cobj, ...)
	mtask.send(service, "lua", "confirm" , cobj)
	return ret
end

return sharedata
