local mtask = require "mtask"
local core = require "mtask.core"
require "mtask.manager"	-- import manager apis
local string = string

local services = {}
local command = {}
local instance = {} -- for confirm (function command.LAUNCH / command.ERROR / command.LAUNCHOK)

local function handle_to_address(handle)
	return tonumber("0x" .. string.sub(handle , 2))
end

local NORET = {}

function command.LIST()
	mtask.error(string.format("launcher.lua command.LIST"))
	local list = {}
	for k,v in pairs(services) do
		list[mtask.address(k)] = v
	end
	return list
end

function command.STAT()
	mtask.error(string.format("launcher.lua command.STAT"))
	local list = {}
	for k,v in pairs(services) do
		local ok, stat = pcall(mtask.call,k,"debug","STAT")
		if not ok then
			stat = string.format("ERROR (%s)",v)
		end
		list[mtask.address(k)] = stat
	end
	return list
end

function command.KILL(_, handle)
	mtask.error(string.format("launcher.lua command.KILL %s",handle))
	handle = handle_to_address(handle)
	mtask.kill(handle)
	local ret = { [mtask.address(handle)] = tostring(services[handle]) }
	services[handle] = nil
	return ret
end

function command.MEM()
	mtask.error(string.format("launcher.lua command.MEM"))
	local list = {}
	for k,v in pairs(services) do
		local ok, kb, bytes = pcall(mtask.call,k,"debug","MEM")
		if not ok then
			list[mtask.address(k)] = string.format("ERROR (%s)",v)
		else
			list[mtask.address(k)] = string.format("%.2f Kb (%s)",kb,v)
		end
	end
	return list
end

function command.GC()
	mtask.error(string.format("launcher.lua command.GC"))
	for k,v in pairs(services) do
		mtask.send(k,"debug","GC")
	end
	return command.MEM()
end

function command.REMOVE(_, handle, kill)
	mtask.error(string.format("launcher.lua command.REMOVE %s",handle))
	services[handle] = nil
	local response = instance[handle]
	if response then
		-- instance is dead
		response(not kill)	-- return nil to caller of newservice, when kill == false
		instance[handle] = nil
	end

	-- don't return (mtask.ret) because the handle may exit
	return NORET
end

local function launch_service(service, ...)
	local param = table.concat({...}, " ")
	-- service 为要启动的服务名 param 为以空格分开的参数
	local inst = mtask.launch(service, param)
	local response = mtask.response()
	if inst then
		services[inst] = service .. " " .. param
		instance[inst] = response
	else
		response(false)
		return
	end
	return inst
end
-- _为发送此消息的源地址 service一般为启动lua服务的中介 (一般为 snlua)
function command.LAUNCH(_, service, ...)
	mtask.error(string.format("launcher.lua command.LAUNCH %s",service))
	launch_service(service, ...) -- service 为服务模块名，... 为创建服务时传递进去的参数
	return NORET
end

function command.LOGLAUNCH(_, service, ...)
	mtask.error(string.format("launcher.lua command.LOGLAUNCH %s",service))
	local inst = launch_service(service, ...)
	if inst then
		core.command("LOGON", mtask.address(inst))
	end
	return NORET
end

function command.ERROR(address)
	mtask.error(string.format("launcher.lua command.ERROR %s",address))
	-- see serivce-src/service_lua.c
	-- init failed
	local response = instance[address]
	if response then
		response(false)
		instance[address] = nil
	end
	services[address] = nil
	return NORET
end

function command.LAUNCHOK(address)
	mtask.error(string.format("launcher.lua command.LAUNCHOK %s",address))
	-- init notice
	local response = instance[address]
	if response then
		response(true, address)
		instance[address] = nil
	end

	return NORET
end

-- for historical reasons, launcher support text command (for C service)

mtask.register_protocol {
	name = "text",
	id = mtask.PTYPE_TEXT,
	unpack = mtask.tostring,
	dispatch = function(session, address , cmd)
		if cmd == "" then
			command.LAUNCHOK(address)
		elseif cmd == "ERROR" then
			command.ERROR(address)
		else
			error ("Invalid text command " .. cmd)
		end
	end,
}

mtask.dispatch("lua", function(session, source, cmd , ...)
	mtask.error(string.format("launcher.lua dispatch %s %s %s",session,source,cmd))
	cmd = string.upper(cmd)
	local f = command[cmd]
	if f then
		local ret = f(source, ...)
		if ret ~= NORET then
			mtask.ret(mtask.pack(ret))
		end
	else
		mtask.ret(mtask.pack {"Unknown command"} )
	end
end)

mtask.start(function()
	mtask.error("launcher.lua start")
 end)
