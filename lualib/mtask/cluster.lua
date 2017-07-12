local mtask = require "mtask"

local clusterd
local cluster = {}

function cluster.call(node, address, ...)
	-- mtask.pack(...) will free by cluster.core.packrequest
	return mtask.call(clusterd, "lua", "req", node, address, mtask.pack(...))
end

function cluster.send(node, address, ...)
	-- push is the same with req, but no response
	mtask.send(clusterd, "lua", "push", node, address, mtask.pack(...))
end

function cluster.open(port)
	if type(port) == "string" then
		mtask.call(clusterd, "lua", "listen", port)
	else
		mtask.call(clusterd, "lua", "listen", "0.0.0.0", port)
	end
end

function cluster.reload(config)
	mtask.call(clusterd, "lua", "reload", config)
end

function cluster.proxy(node, name)
	return mtask.call(clusterd, "lua", "proxy", node, name)
end

function cluster.snax(node, name, address)
	local snax = require "mtask.snax"
	if not address then
		address = cluster.call(node, ".service", "QUERY", "snaxd" , name)
	end
	local handle = mtask.call(clusterd, "lua", "proxy", node, address)
	return snax.bind(handle, name)
end

function cluster.register(name, addr)
	assert(type(name) == "string")
	assert(addr == nil or type(addr) == "number")
	return mtask.call(clusterd, "lua", "register", name, addr)
end

function cluster.query(node, name)
	-- 注意第5个参数为0
	return mtask.call(clusterd, "lua", "req", node, 0, mtask.pack(name))
end

mtask.init(function()
	clusterd = mtask.uniqueservice("clusterd")
end)

return cluster
