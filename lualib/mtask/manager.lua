local mtask = require "mtask"
local c = require "mtask.core"

function mtask.launch(...)
	local addr = c.command("LAUNCH", table.concat({...}," "))
	if addr then
		return tonumber("0x" .. string.sub(addr , 2))
	end
end

function mtask.kill(name)
	if type(name) == "number" then
		mtask.send(".launcher","lua","REMOVE",name, true)
		name = mtask.address(name)
	end
	c.command("KILL",name)
end

function mtask.abort()
	c.command("ABORT")
end

local function globalname(name, handle)
	local c = string.sub(name,1,1)
	assert(c ~= ':')
	if c == '.' then
		return false
	end

	assert(#name <= 16)	-- GLOBALNAME_LENGTH is 16, defined in mtask_harbor.h
	assert(tonumber(name) == nil)	-- global name can't be number

	local harbor = require "mtask.harbor"

	harbor.globalname(name, handle)

	return true
end

function mtask.register(name)
	if not globalname(name) then
		c.command("REG", name)
	end
end

function mtask.name(name, handle)
	if not globalname(name, handle) then
		c.command("NAME", name .. " " .. mtask.address(handle))
	end
end

local dispatch_message = mtask.dispatch_message

function mtask.forward_type(map, start_func)
	c.callback(function(ptype, msg, sz, ...)
		local prototype = map[ptype]
		if prototype then
			dispatch_message(prototype, msg, sz, ...)
		else
			dispatch_message(ptype, msg, sz, ...)
			c.trash(msg, sz)
		end
	end, true)
	mtask.timeout(0, function()
		mtask.init_service(start_func)
	end)
end

function mtask.filter(f ,start_func)
	c.callback(function(...)
		dispatch_message(f(...))
	end)
	mtask.timeout(0, function()
		mtask.init_service(start_func)
	end)
end

function mtask.monitor(service, query)
	local monitor
	if query then
		monitor = mtask.queryservice(true, service)
	else
		monitor = mtask.uniqueservice(true, service)
	end
	assert(monitor, "Monitor launch failed")
	c.command("MONITOR", string.format(":%08x", monitor))
	return monitor
end

return mtask
