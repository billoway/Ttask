local mtask = require "mtask"
require "mtask.manager"

mtask.register_protocol {
	name = "text",
	id = mtask.PTYPE_TEXT,
	unpack = mtask.tostring,
	dispatch = function(_, address, msg)
		print(string.format("%x(%.2f): %s", address, mtask.time(), msg))
	end
}

mtask.start(function()
	mtask.register ".logger"
end)