local mtask = require "mtask"

local service = {}
local cache = {}
local provider

local function get_provider()
	provider = provider or mtask.uniqueservice "service_provider"
	return provider
end

local function check(func)
	local info = debug.getinfo(func, "u")
	assert(info.nups == 1)
	assert(debug.getupvalue(func,1) == "_ENV")
end

function service.new(name, mainfunc, ...)
	local p = get_provider()
	local addr, booting = mtask.call(p, "lua", "test", name)
	local address
	if addr then
		address = addr
	else
		if booting then
			address = mtask.call(p, "lua", "query", name)
		else
			check(mainfunc)
			local code = string.dump(mainfunc)
			address = mtask.call(p, "lua", "launch", name, code, ...)
		end
	end
	cache[name] = address
	return address
end

function service.query(name)
	if not cache[name] then
		cache[name] = mtask.call(get_provider(), "lua", "query", name)
	end
	return cache[name]
end

return service
