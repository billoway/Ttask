local mtask = require "mtask"
require "mtask.manager"

mtask.register_protocol {
	name = "text",
	id = mtask.PTYPE_TEXT,
	unpack = mtask.tostring,
	dispatch = function(_, address, msg)
		print(string.format(":%08x(%.2f): %s", address, mtask.time(), msg))
	end
}

mtask.register_protocol {
	name = "SYSTEM",
	id = mtask.PTYPE_SYSTEM,
	unpack = function(...) return ... end,
	dispatch = function()
		-- reopen signal
		print("SIGHUP")
	end
}

mtask.start(function()
	mtask.register ".logger"
end)
