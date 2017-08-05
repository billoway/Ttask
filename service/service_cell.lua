local mtask = require "mtask"

local service_name = (...)
local init = {}

function init.init(code, ...)
	mtask.error("service_cell.lua  init")
	mtask.dispatch("lua", function() error("No dispatch function")	end)
	mtask.start = function(f) f()	end
	local mainfunc = assert(load(code, service_name))
	mainfunc(...)
	mtask.ret()
end

mtask.start(function()
	mtask.error("service_cell.lua  start")
	mtask.dispatch("lua", function(_,_,cmd,...)
		init[cmd](...)
	end)
	mtask.error("service_cell.lua  booted")
end)
