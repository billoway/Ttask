local mtask = require "mtask"
require "mtask.manager"	-- import mtask.register

mtask.start(function()
	mtask.dispatch("lua", function(session, address, ...)
		print("[GLOBALLOG]", mtask.address(address), ...)
	end)
	mtask.register ".log"
	mtask.register "LOG"
end)
