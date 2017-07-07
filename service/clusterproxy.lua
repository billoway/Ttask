local mtask = require "mtask"
local cluster = require "mtask.cluster"
require "mtask.manager"	-- inject mtask.forward_type

local node, address = ...

mtask.register_protocol {
	name = "system",
	id = mtask.PTYPE_SYSTEM,
	unpack = function (...) return ... end,
}

local forward_map = {
	[mtask.PTYPE_SNAX] = mtask.PTYPE_SYSTEM,
	[mtask.PTYPE_LUA] = mtask.PTYPE_SYSTEM,
	[mtask.PTYPE_RESPONSE] = mtask.PTYPE_RESPONSE,	-- don't free response message
}

mtask.forward_type( forward_map ,function()
	local clusterd = mtask.uniqueservice("clusterd")
	local n = tonumber(address)
	if n then
		address = n
	end
	mtask.dispatch("system", function (session, source, msg, sz)
		if session == 0 then
			mtask.send(clusterd, "lua", "push", node, address, msg, sz)
		else
			mtask.ret(mtask.rawcall(clusterd, "lua", mtask.pack("req", node, address, msg, sz)))
		end
	end)
end)
