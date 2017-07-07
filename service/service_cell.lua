local mtask = require "mtask"

local service_name = (...)
local init = {}

function init.init(code, ...)
	mtask.dispatch("lua", function() error("No dispatch function")	end)
	mtask.start = function(f) f()	end
	local mainfunc = assert(load(code, service_name))
	mainfunc(...)
	mtask.ret()
end

mtask.start(function()
	mtask.dispatch("lua", function(_,_,cmd,...)
		init[cmd](...)
	end)
end)
