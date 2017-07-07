local mtask = require "mtask"

local datacenter = {}

function datacenter.get(...)
	return mtask.call("DATACENTER", "lua", "QUERY", ...)
end

function datacenter.set(...)
	return mtask.call("DATACENTER", "lua", "UPDATE", ...)
end

function datacenter.wait(...)
	return mtask.call("DATACENTER", "lua", "WAIT", ...)
end

return datacenter

