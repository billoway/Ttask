local mtask = require "mtask"

-- It's a simple service exit monitor, you can do something more when a service exit.

local service_map = {}

mtask.register_protocol {
	name = "client",
	id = mtask.PTYPE_CLIENT,	-- PTYPE_CLIENT = 3
	unpack = function() end,
	dispatch = function(_, address)
		local w = service_map[address]
		if w then
			for watcher in pairs(w) do
				mtask.redirect(watcher, address, "error", 0, "")
			end
			service_map[address] = false
		end
	end
}

local function monitor(session, watcher, command, service)
	assert(command, "WATCH")
	local w = service_map[service]
	if not w then
		if w == false then
			mtask.ret(mtask.pack(false))
			return
		end
		w = {}
		service_map[service] = w
	end
	w[watcher] = true
	mtask.ret(mtask.pack(true))
end

mtask.start(function()
	mtask.dispatch("lua", monitor)
end)
