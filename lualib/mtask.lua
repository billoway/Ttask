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
--让框架在 ti 个单位时间后，调用 func 这个函数。
--非阻塞 API ，当前 coroutine 会继续向下运行，而 func 将来会在新的 coroutine 中执行。
--mtask 的定时器实现的非常高效，所以一般不用太担心性能问题。不过，如果你的服务想大量使用定时器的话，可以考虑一个更好的方法：即在一个service里，尽量只使用一个 mtask.timeout ，用它来触发自己的定时事件模块。这样可以减少大量从框架发送到服务的消息数量。毕竟一个服务在同一个单位时间能处理的外部消息数量是有限的。

--timeout 没有取消接口，这是因为你可以简单的封装它获得取消的能力
function mtask.timeout(ti, func)
	local session = c.intcommand("TIMEOUT",ti)
	assert(session)
	local co = co_create(func)
	assert(session_id_coroutine[session] == nil)
	session_id_coroutine[session] = co
end
--阻塞 API
--将当前 coroutine 挂起 ti 个单位时间。一个单位是 1/100 秒。
--它是向框架注册一个定时器实现的。框架会在 ti 时间后，发送一个定时器消息来唤醒这个 coroutine 。
--它的返回值会告诉你是时间到了，还是被 mtask.wakeup 唤醒 （返回 "BREAK"）
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
-- 相当于 mtask.sleep(0) 。交出当前服务对 CPU 的控制权。
--通常在你想做大量的操作，又没有机会调用阻塞 API 时，可以选择调用 yield 让系统跑的更平滑
function mtask.yield()
	return mtask.sleep(0)
end
-- 把当前 coroutine 挂起。通常这个函数需要结合 mtask.wakeup 使用
function mtask.wait()
	local session = c.genid()
	local ret, msg = coroutine_yield("SLEEP", session)
	local co = coroutine.running()
	sleep_session[co] = nil
	session_id_coroutine[session] = nil
end
--用于获得服务自己的地址
local self_handle
function mtask.self()
	if self_handle then
		return self_handle
	end
	self_handle = string_to_handle(c.command("REG"))
	return self_handle
end
--用来查询一个 . 开头的名字对应的地址。它是一个非阻塞 API ，不可以查询跨节点的全局名字。
function mtask.localname(name)
	local addr = c.command("QUERY", name)
	if addr then
		return string_to_handle(addr)
	end
end
--返回 mtask 节点进程启动的时间。
--这个返回值的数值本身意义不大，不同节点在同一时刻取到的值也不相同。
--只有两次调用的差值才有意义.用来测量经过的时间。每 100 表示真实时间 1 秒。
--这个函数的开销小于查询系统时钟。在同一个时间片内这个值是不变的。
--(注意:这里的时间片表示小于mtask内部时钟周期的时间片,假如执行了比较费时的操作如超长时间的循环,或者调用了外部的阻塞调用,如os.execute('sleep 1'), 即使中间没有mtask的阻塞api调用,两次调用的返回值还是会不同的.)
function mtask.now()
	return c.intcommand("NOW")
end
--返回 mtask 节点进程启动的 UTC 时间，以秒为单位
function mtask.starttime()
	return c.intcommand("STARTTIME")
end
--返回以秒为单位（精度为小数点后两位）的 UTC 时间。
function mtask.time()
	return mtask.now()/100 + mtask.starttime()	-- get now first would be better
end
--用于退出当前的服务;mtask.exit 之后的代码都不会被运行
--而且，当前服务被阻塞住的 coroutine 也会立刻中断退出。
--这些通常是一些 RPC 尚未收到回应。所以调用 mtask.exit() 请务必小心。
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
--获取mtask 环境变量
function mtask.getenv(key)
	local ret = c.command("GETENV",key)
	if ret == "" then
		return
	else
		return ret
	end
end
--设置mtask 环境变量
function mtask.setenv(key, value)
	c.command("SETENV",key .. " " ..value)
end
--非阻塞 API ，发送完消息后，coroutine 会继续向下运行，这期间服务不会重入
--把一条类别为 typename 的消息发送给 address 
--它会先经过事先注册的 pack 函数打包 ... 的内容
function mtask.send(addr, typename, ...)
	local p = proto[typename]
	return c.send(addr, p.id, 0 , p.pack(...))
end
--生成一个唯一 session 号
mtask.genid = assert(c.genid)
-- 和 mtask.send 功能类似，但更细节一些。
--它可以指定发送地址（把消息源伪装成另一个服务），指定发送的消息的 session 。
--注：dest 和 source 都必须是数字地址，不可以是别名。
--mtask.redirect 不会调用 pack ，所以这里的 ... 必须是一个编码过的字符串，或是 userdata 加一个长度。
mtask.redirect = function(dest,source,typename,...)
	return c.redirect(dest, source, proto[typename].id, ...)
end

mtask.pack = assert(c.pack)--lua 数据结构序列化
mtask.packstring = assert(c.packstring)
mtask.unpack = assert(c.unpack)--lua 数据结构反序列化
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
--它会在内部生成一个唯一 session ，并向 address 提起请求，并阻塞等待对 session 的回应（可以不由 address 回应）
--当消息回应后，还会通过之前注册的 unpack 函数解包。
--表面上看起来，就是发起了一次 RPC ，并阻塞等待回应。
--call 不支持超时
--尤其需要留意的是，mtask.call 仅仅阻塞住当前的 coroutine ，而没有阻塞整个服务.
--在等待回应期间，服务照样可以响应其他请求。
--所以，尤其要注意，在 mtask.call 之前获得的服务内的状态，到返回后，很有可能改变。
function mtask.call(addr, typename, ...)
	local p = proto[typename]
	local session = c.send(addr, p.id , nil , p.pack(...))
	if session == nil then
		error("call to invalid address " .. mtask.address(addr))
	end
	return p.unpack(yield_call(addr, session))
end
--和 mtask.call 功能类似（也是阻塞 API）。
--但发送时不经过 pack 打包流程，收到回应后，也不走 unpack 流程。
function mtask.rawcall(addr, typename, msg, sz)
	local p = proto[typename]
	local session = assert(c.send(addr, p.id , nil , msg, sz), "call to invalid address")
	return yield_call(addr, session)
end
--非阻塞 API
--回应一个消息,
--在同一个消息处理的 coroutine 中只可以被调用一次，多次调用会触发异常
--有时候，你需要挂起一个请求，等将来时机满足，再回应它.
--而回应的时候已经在别的 coroutine 中了。
--针对这种情况，你可以调用 mtask.response(mtask.pack) 获得一个闭包，以后调用这个闭包即可把回应消息发回。
--这里的参数 mtask.pack 是可选的，你可以传入其它打包函数，默认即是 mtask.pack 。
function mtask.ret(msg, sz)
	msg = msg or ""
	return coroutine_yield("RETURN", msg, sz)
end
--非阻塞 API
--返回的闭包可用于延迟回应。
--调用它时，第一个参数通常是 true 表示是一个正常的回应，之后的参数是需要回应的数据。
--如果是 false ，则给请求者抛出一个异常。
--它的返回值表示回应的地址是否还有效。
--如果你仅仅想知道回应地址的有效性，那么可以在第一个参数传入 "TEST" 用于检测。
function mtask.response(pack)
	pack = pack or mtask.pack
	return coroutine_yield("RESPONSE", pack)
end

function mtask.retpack(...)
	return mtask.ret(mtask.pack(...))
end
-- 唤醒一个被 mtask.sleep 或 mtask.wait 挂起的 coroutine 。
--目前的版本则可以保证次序
function mtask.wakeup(co)
	if sleep_session[co] and wakeup_session[co] == nil then
		wakeup_session[co] = true
		return true
	end
end
--Lua API 消息分发注册特定类消息的处理函数。大多数程序会注册 lua 类消息的处理函数
--dispatch 函数会在收到每条类别对应的消息时被回调。
--消息先经过 unpack 函数，返回值被传入 dispatch 。
--每条消息的处理都工作在一个独立的 coroutine 中，看起来以多线程方式工作。
--但记住，在同一个 lua 虚拟机（同一个 lua 服务）中，永远不可能出现多线程并发的情况
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
--从功能上，它等价于 mtask.timeout(0, function() func(...) end) 但是比 timeout 高效一点。因为它并不需要向框架注册一个定时器
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
--阻塞 API
--用于启动一个新的 Lua 服务.
--name 是脚本的名字（不用写 .lua 后缀）。
--只有被启动的脚本的 start 函数返回后，这个 API 才会返回启动的服务的地址.
--如果被启动的脚本在初始化环节抛出异常，或在初始化完成前就调用 mtask.exit 退出，｀mtask.newservice` 都会抛出异常。
--如果被启动的脚本的 start 函数是一个永不结束的循环，那么 newservice 也会被永远阻塞住。
--注意：启动参数其实是以字符串拼接的方式传递过去的.

--目前推荐的惯例是，让你的服务响应一个启动消息。在 newservice 之后，立刻调用 mtask.call 发送启动请求
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
--用于把一个地址数字转换为一个可用于阅读的字符串
function mtask.address(addr)
	if type(addr) == "number" then
		return string.format(":%08x",addr)
	else
		return tostring(addr)
	end
end
 --用于获得服务所属的节点
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
--阻塞 API ，可以用 mtask.init 把一些工作注册在 start 之前
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
--每个 mtask 服务都必须有一个启动函数。
--这一点和普通 Lua 脚本不同，传统的 Lua 脚本是没有专门的主函数，脚本本身即是主函数。
--而 mtask 服务，你必须主动调用 mtask.start(function() ... end) 。

--当然你还是可以在脚本中随意写一段 Lua 代码，它们会先于 start 函数执行。
--但是，不要在外面调用 mtask 的阻塞 API ，因为框架将无法唤醒它们。

--如果你想在 mtask.start 注册的函数之前做点什么，可以调用 mtask.init(function() ... end) 。这通常用于 lua 库的编写.
--你需要编写的服务引用你的库的时候，事先调用一些 mtask 阻塞 API ，就可以用 mtask.init 把这些工作注册在 start 之前.
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
