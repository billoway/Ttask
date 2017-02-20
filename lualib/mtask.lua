local c = require "mtask.core"
local tostring = tostring
local tonumber = tonumber
local coroutine = coroutine
local assert = assert
local pairs = pairs
local pcall = pcall

local profile = require "profile"

coroutine.resume = profile.resume
coroutine.yield = profile.yield

local proto = {}
local mtask = {
	-- read mtask.h
	PTYPE_TEXT = 0,
	PTYPE_RESPONSE = 1,
	PTYPE_MULTICAST = 2,
	PTYPE_CLIENT = 3,
	PTYPE_SYSTEM = 4,
	PTYPE_HARBOR = 5,
	PTYPE_SOCKET = 6,
	PTYPE_ERROR = 7,
	PTYPE_QUEUE = 8,	-- used in deprecated mqueue, use mtask.queue instead
	PTYPE_DEBUG = 9,
	PTYPE_LUA = 10,
	PTYPE_SNAX = 11,
}

-- code cache
mtask.cache = require "mtask.codecache"

function mtask.register_protocol(class)
	local name = class.name
	local id = class.id
	assert(proto[name] == nil)
	assert(type(name) == "string" and type(id) == "number" and id >=0 and id <=255)
	proto[name] = class
	proto[id] = class
end

local session_id_coroutine = {}
local session_coroutine_id = {}
local session_coroutine_address = {}
local session_response = {}
local unresponse = {}

local wakeup_session = {}
local sleep_session = {}

local watching_service = {}
local watching_session = {}
local dead_service = {}
local error_queue = {}
local fork_queue = {}

-- suspend is function
local suspend

local function string_to_handle(str)
	return tonumber("0x" .. string.sub(str , 2))
end

----- monitor exit

local function dispatch_error_queue()
	local session = table.remove(error_queue,1)
	if session then
		local co = session_id_coroutine[session]
		session_id_coroutine[session] = nil
		return suspend(co, coroutine.resume(co, false))
	end
end

local function _error_dispatch(error_session, error_source)
	if error_session == 0 then
		-- service is down
		--  Don't remove from watching_service , because user may call dead service
		if watching_service[error_source] then
			dead_service[error_source] = true
		end
		for session, srv in pairs(watching_session) do
			if srv == error_source then
				table.insert(error_queue, session)
			end
		end
	else
		-- capture an error for error_session
		if watching_session[error_session] then
			table.insert(error_queue, error_session)
		end
	end
end

-- coroutine reuse

local coroutine_pool = {}
local coroutine_yield = coroutine.yield

local function co_create(f)
	local co = table.remove(coroutine_pool)
	if co == nil then
		co = coroutine.create(function(...)
			f(...)
			while true do
				f = nil
				coroutine_pool[#coroutine_pool+1] = co
				f = coroutine_yield "EXIT"
				f(coroutine_yield())
			end
		end)
	else
		coroutine.resume(co, f)
	end
	return co
end

local function dispatch_wakeup()
	local co = next(wakeup_session)
	if co then
		wakeup_session[co] = nil
		local session = sleep_session[co]
		if session then
			session_id_coroutine[session] = "BREAK"
			return suspend(co, coroutine.resume(co, false, "BREAK"))
		end
	end
end

local function release_watching(address)
	local ref = watching_service[address]
	if ref then
		ref = ref - 1
		if ref > 0 then
			watching_service[address] = ref
		else
			watching_service[address] = nil
		end
	end
end

-- suspend is local function
function suspend(co, result, command, param, size)
	if not result then
		local session = session_coroutine_id[co]
		if session then -- coroutine may fork by others (session is nil)
			local addr = session_coroutine_address[co]
			if session ~= 0 then
				-- only call response error
				c.send(addr, mtask.PTYPE_ERROR, session, "")
			end
			session_coroutine_id[co] = nil
			session_coroutine_address[co] = nil
		end
		error(debug.traceback(co,tostring(command)))
	end
	if command == "CALL" then
		session_id_coroutine[param] = co
	elseif command == "SLEEP" then
		session_id_coroutine[param] = co
		sleep_session[co] = param
	elseif command == "RETURN" then
		local co_session = session_coroutine_id[co]
		local co_address = session_coroutine_address[co]
		if param == nil or session_response[co] then
			error(debug.traceback(co))
		end
		session_response[co] = true
		local ret
		if not dead_service[co_address] then
			ret = c.send(co_address, mtask.PTYPE_RESPONSE, co_session, param, size) ~= nil
			if not ret then
				-- If the package is too large, returns nil. so we should report error back
				c.send(co_address, mtask.PTYPE_ERROR, co_session, "")
			end
		elseif size ~= nil then
			c.trash(param, size)
			ret = false
		end
		return suspend(co, coroutine.resume(co, ret))
	elseif command == "RESPONSE" then
		local co_session = session_coroutine_id[co]
		local co_address = session_coroutine_address[co]
		if session_response[co] then
			error(debug.traceback(co))
		end
		local f = param
		local function response(ok, ...)
			if ok == "TEST" then
				if dead_service[co_address] then
					release_watching(co_address)
					f = false
					return false
				else
					return true
				end
			end
			if not f then
				if f == false then
					f = nil
					return false
				end
				error "Can't response more than once"
			end

			local ret
			if not dead_service[co_address] then
				if ok then
					ret = c.send(co_address, mtask.PTYPE_RESPONSE, co_session, f(...)) ~= nil
					if not ret then
						-- If the package is too large, returns false. so we should report error back
						c.send(co_address, mtask.PTYPE_ERROR, co_session, "")
					end
				else
					ret = c.send(co_address, mtask.PTYPE_ERROR, co_session, "") ~= nil
				end
			else
				ret = false
			end
			release_watching(co_address)
			unresponse[response] = nil
			f = nil
			return ret
		end
		watching_service[co_address] = watching_service[co_address] + 1
		session_response[co] = response
		unresponse[response] = true
		return suspend(co, coroutine.resume(co, response))
	elseif command == "EXIT" then
		-- coroutine exit
		local address = session_coroutine_address[co]
		release_watching(address)
		session_coroutine_id[co] = nil
		session_coroutine_address[co] = nil
		session_response[co] = nil
	elseif command == "QUIT" then
		-- service exit
		return
	elseif command == nil then
		-- debug trace
		return
	else
		error("Unknown command : " .. command .. "\n" .. debug.traceback(co))
	end
	dispatch_wakeup()
	dispatch_error_queue()
end

function mtask.timeout(ti, func)
	local session = c.intcommand("TIMEOUT",ti)
	assert(session)
	local co = co_create(func)
	assert(session_id_coroutine[session] == nil)
	session_id_coroutine[session] = co
end

function mtask.sleep(ti)
	local session = c.intcommand("TIMEOUT",ti)
	assert(session)
	local succ, ret = coroutine_yield("SLEEP", session)
	sleep_session[coroutine.running()] = nil
	if succ then
		return
	end
	if ret == "BREAK" then
		return "BREAK"
	else
		error(ret)
	end
end

function mtask.yield()
	return mtask.sleep(0)
end

function mtask.wait()
	local session = c.genid()
	local ret, msg = coroutine_yield("SLEEP", session)
	local co = coroutine.running()
	sleep_session[co] = nil
	session_id_coroutine[session] = nil
end

local self_handle
function mtask.self()
	if self_handle then
		return self_handle
	end
	self_handle = string_to_handle(c.command("REG"))
	return self_handle
end

function mtask.localname(name)
	local addr = c.command("QUERY", name)
	if addr then
		return string_to_handle(addr)
	end
end

function mtask.now()
	return c.intcommand("NOW")
end

function mtask.starttime()
	return c.intcommand("STARTTIME")
end

function mtask.time()
	return mtask.now()/100 + mtask.starttime()	-- get now first would be better
end

function mtask.exit()
	fork_queue = {}	-- no fork coroutine can be execute after mtask.exit
	mtask.send(".launcher","lua","REMOVE",mtask.self(), false)
	-- report the sources that call me
	for co, session in pairs(session_coroutine_id) do
		local address = session_coroutine_address[co]
		if session~=0 and address then
			c.redirect(address, 0, mtask.PTYPE_ERROR, session, "")
		end
	end
	for resp in pairs(unresponse) do
		resp(false)
	end
	-- report the sources I call but haven't return
	local tmp = {}
	for session, address in pairs(watching_session) do
		tmp[address] = true
	end
	for address in pairs(tmp) do
		c.redirect(address, 0, mtask.PTYPE_ERROR, 0, "")
	end
	c.command("EXIT")
	-- quit service
	coroutine_yield "QUIT"
end

function mtask.getenv(key)
	local ret = c.command("GETENV",key)
	if ret == "" then
		return
	else
		return ret
	end
end

function mtask.setenv(key, value)
	c.command("SETENV",key .. " " ..value)
end

function mtask.send(addr, typename, ...)
	local p = proto[typename]
	return c.send(addr, p.id, 0 , p.pack(...))
end

mtask.genid = assert(c.genid)

mtask.redirect = function(dest,source,typename,...)
	return c.redirect(dest, source, proto[typename].id, ...)
end

mtask.pack = assert(c.pack)
mtask.packstring = assert(c.packstring)
mtask.unpack = assert(c.unpack)
mtask.tostring = assert(c.tostring)
mtask.trash = assert(c.trash)

local function yield_call(service, session)
	watching_session[session] = service
	local succ, msg, sz = coroutine_yield("CALL", session)
	watching_session[session] = nil
	if not succ then
		error "call failed"
	end
	return msg,sz
end

function mtask.call(addr, typename, ...)
	local p = proto[typename]
	local session = c.send(addr, p.id , nil , p.pack(...))
	if session == nil then
		error("call to invalid address " .. mtask.address(addr))
	end
	return p.unpack(yield_call(addr, session))
end

function mtask.rawcall(addr, typename, msg, sz)
	local p = proto[typename]
	local session = assert(c.send(addr, p.id , nil , msg, sz), "call to invalid address")
	return yield_call(addr, session)
end

function mtask.ret(msg, sz)
	msg = msg or ""
	return coroutine_yield("RETURN", msg, sz)
end

function mtask.response(pack)
	pack = pack or mtask.pack
	return coroutine_yield("RESPONSE", pack)
end

function mtask.retpack(...)
	return mtask.ret(mtask.pack(...))
end

function mtask.wakeup(co)
	if sleep_session[co] and wakeup_session[co] == nil then
		wakeup_session[co] = true
		return true
	end
end

function mtask.dispatch(typename, func)
	local p = proto[typename]
	if func then
		local ret = p.dispatch
		p.dispatch = func
		return ret
	else
		return p and p.dispatch
	end
end

local function unknown_request(session, address, msg, sz, prototype)
	mtask.error(string.format("Unknown request (%s): %s", prototype, c.tostring(msg,sz)))
	error(string.format("Unknown session : %d from %x", session, address))
end

function mtask.dispatch_unknown_request(unknown)
	local prev = unknown_request
	unknown_request = unknown
	return prev
end

local function unknown_response(session, address, msg, sz)
	mtask.error(string.format("Response message : %s" , c.tostring(msg,sz)))
	error(string.format("Unknown session : %d from %x", session, address))
end

function mtask.dispatch_unknown_response(unknown)
	local prev = unknown_response
	unknown_response = unknown
	return prev
end

local tunpack = table.unpack

function mtask.fork(func,...)
	local args = { ... }
	local co = co_create(function()
		func(tunpack(args))
	end)
	table.insert(fork_queue, co)
	return co
end

local function raw_dispatch_message(prototype, msg, sz, session, source, ...)
	-- mtask.PTYPE_RESPONSE = 1, read mtask.h
	if prototype == 1 then
		local co = session_id_coroutine[session]
		if co == "BREAK" then
			session_id_coroutine[session] = nil
		elseif co == nil then
			unknown_response(session, source, msg, sz)
		else
			session_id_coroutine[session] = nil
			suspend(co, coroutine.resume(co, true, msg, sz))
		end
	else
		local p = proto[prototype]
		if p == nil then
			if session ~= 0 then
				c.send(source, mtask.PTYPE_ERROR, session, "")
			else
				unknown_request(session, source, msg, sz, prototype)
			end
			return
		end
		local f = p.dispatch
		if f then
			local ref = watching_service[source]
			if ref then
				watching_service[source] = ref + 1
			else
				watching_service[source] = 1
			end
			local co = co_create(f)
			session_coroutine_id[co] = session
			session_coroutine_address[co] = source
			suspend(co, coroutine.resume(co, session,source, p.unpack(msg,sz, ...)))
		else
			unknown_request(session, source, msg, sz, proto[prototype].name)
		end
	end
end

function mtask.dispatch_message(...)
	local succ, err = pcall(raw_dispatch_message,...)
	while true do
		local key,co = next(fork_queue)
		if co == nil then
			break
		end
		fork_queue[key] = nil
		local fork_succ, fork_err = pcall(suspend,co,coroutine.resume(co))
		if not fork_succ then
			if succ then
				succ = false
				err = tostring(fork_err)
			else
				err = tostring(err) .. "\n" .. tostring(fork_err)
			end
		end
	end
	assert(succ, tostring(err))
end

function mtask.newservice(name, ...)
	return mtask.call(".launcher", "lua" , "LAUNCH", "snlua", name, ...)
end

function mtask.uniqueservice(global, ...)
	if global == true then
		return assert(mtask.call(".service", "lua", "GLAUNCH", ...))
	else
		return assert(mtask.call(".service", "lua", "LAUNCH", global, ...))
	end
end

function mtask.queryservice(global, ...)
	if global == true then
		return assert(mtask.call(".service", "lua", "GQUERY", ...))
	else
		return assert(mtask.call(".service", "lua", "QUERY", global, ...))
	end
end

function mtask.address(addr)
	if type(addr) == "number" then
		return string.format(":%08x",addr)
	else
		return tostring(addr)
	end
end

function mtask.harbor(addr)
	return c.harbor(addr)
end

function mtask.error(...)
	local t = {...}
	for i=1,#t do
		t[i] = tostring(t[i])
	end
	return c.error(table.concat(t, " "))
end

----- register protocol
do
	local REG = mtask.register_protocol

	REG {
		name = "lua",
		id = mtask.PTYPE_LUA,
		pack = mtask.pack,
		unpack = mtask.unpack,
	}

	REG {
		name = "response",
		id = mtask.PTYPE_RESPONSE,
	}

	REG {
		name = "error",
		id = mtask.PTYPE_ERROR,
		unpack = function(...) return ... end,
		dispatch = _error_dispatch,
	}
end

local init_func = {}

function mtask.init(f, name)
	assert(type(f) == "function")
	if init_func == nil then
		f()
	else
		if name == nil then
			table.insert(init_func, f)
		else
			assert(init_func[name] == nil)
			init_func[name] = f
		end
	end
end

local function init_all()
	local funcs = init_func
	init_func = nil
	if funcs then
		for k,v in pairs(funcs) do
			v()
		end
	end
end

local function init_template(start)
	init_all()
	init_func = {}
	start()
	init_all()
end

function mtask.pcall(start)
	return xpcall(init_template, debug.traceback, start)
end

function mtask.init_service(start)
	local ok, err = mtask.pcall(start)
	if not ok then
		mtask.error("init service failed: " .. tostring(err))
		mtask.send(".launcher","lua", "ERROR")
		mtask.exit()
	else
		mtask.send(".launcher","lua", "LAUNCHOK")
	end
end

function mtask.start(start_func)
	c.callback(mtask.dispatch_message)
	mtask.timeout(0, function()
		mtask.init_service(start_func)
	end)
end

function mtask.endless()
	return c.command("ENDLESS")~=nil
end

function mtask.mqlen()
	return c.intcommand "MQLEN"
end

function mtask.task(ret)
	local t = 0
	for session,co in pairs(session_id_coroutine) do
		if ret then
			ret[session] = debug.traceback(co)
		end
		t = t + 1
	end
	return t
end

function mtask.term(service)
	return _error_dispatch(0, service)
end

local function clear_pool()
	coroutine_pool = {}
end

-- Inject internal debug framework
local debug = require "mtask.debug"
debug(mtask, {
	dispatch = mtask.dispatch_message,
	clear = clear_pool,
	suspend = suspend,
})

return mtask
