local mtask = require "mtask"

local harbor = {}

function harbor.globalname(name, handle)
	handle = handle or mtask.self()
	mtask.send(".cslave", "lua", "REGISTER", name, handle)
end

function harbor.queryname(name)
	return mtask.call(".cslave", "lua", "QUERYNAME", name)
end

function harbor.link(id)
	mtask.call(".cslave", "lua", "LINK", id)
end

function harbor.connect(id)
	mtask.call(".cslave", "lua", "CONNECT", id)
end

function harbor.linkmaster()
	mtask.call(".cslave", "lua", "LINKMASTER")
end

return harbor
