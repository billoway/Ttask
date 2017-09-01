local c = require "mtask.core"
local tostring = tostring
local tonumber = tonumber
local coroutine = coroutine
local assert = assert
local pairs = pairs
local pcall = pcall
local table = table
-- profile是一个等同于lua的coroutine，只不过它能记录协程所花的时间
local profile = require "mtask.profile"

local coroutine_resume = profile.resume
local coroutine_yield = profile.yield

local proto = {}
-- 消息类型
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
-- 注册某种类型消息的接口
function mtask.register_protocol(class)
    local name = class.name
    local id = class.id
    assert(proto[name] == nil and proto[id] == nil)
    assert(type(name) == "string" and type(id) == "number" and id >=0 and id <=255)
    proto[name] = class
    proto[id] = class
end
-- 以session为key，协程为value，主要是为了记录session对应的协程，
-- 当服务收到返回值后，可以根据session唤醒相应的协程，返回从另外服务返回的值
local session_id_coroutine = {}
-- 以协程为key，session为value，有消息来时记录下协程对应的session
local session_coroutine_id = {}
-- 以协程为key，发送方服务address为value，有消息来时记录下协程对应的源服务的地址
local session_coroutine_address = {}
-- 以消息的协程co为key，true为value，记录这个协程是不是已经返回它需要的返回值了
local session_response = {}		
--[[
 当A服务调用mtask.response给B想要给B返回值时，以 suspend中的 elseif command == "RESPONSE" then 
 中的 response 函数为key，true为value记录在此表中，这样如果A还没来得及返回时A就要退出了。
 可以从此表中找到response函数，以告诉B(或者其他多个服务)说:"我退出了，你想要的值得不到了"
]]
local unresponse = {}			
-- 当调用mtask.wakeup时，以协程co为key，true为值，压入此队列，等待 dispatch_wakeup 的调用
local wakeup_queue = {}
-- 当调用mtask.sleep时，以协程co为key，session为value的依次压入此队列，
-- 这里的session是定时器创建时返回的
local sleep_session = {}
-- 如果A服务向B服务请求(需要返回值)，那么B服务会以A服务的地址为key，
-- A服务向B服务请求的还在挂起的任务数量的个数为value储存在这个table里面。
local watching_service = {}
-- (调用mtask.call)等待返回值的session(key)对应的服务地址addr(value)
local watching_session = {}
-- 当A服务向B服务发送一个类型为7的消息时，在B服务中会以A服务的地址为key，
-- true为value加入这个table，这样当B返回消息到A时发现A为 dead_service 即丢弃这个消息
local dead_service = {}
-- 如果A服务调用mtask.call向B发起请求，B由于某种错误(通常是调用mtask.exit退出了)不能返回了，
-- B会向A发送一个类型为7的消息，A收到此消息后将错误的session加入此队列的末尾，
-- 等待 dispatch_error_queue 的调用
local error_queue = {}
-- 调用mtask.fork后会创建一个协程co，并将co加入此队列的末尾，等待 mtask.dispatch_message 的调用
local fork_queue = {}

-- suspend is function
-- 类似于前置声明的作用
local suspend
-- 参数为带冒号的16进制数字表示的字符串，返回地址
local function string_to_handle(str)
	return tonumber("0x" .. string.sub(str , 2))
end

----- monitor exit
-- 每执行完一个suspend函数执行一次，从error_queue中取出一个协程并唤醒
local function dispatch_error_queue()
	local session = table.remove(error_queue,1)
	if session then
		local co = session_id_coroutine[session]
		session_id_coroutine[session] = nil
		-- 一般会唤醒mtask.call 中的 yield_call 中的 coroutine_yield("CALL", session) 的执行
		return suspend(co, coroutine_resume(co, false))
	end
end
-- 当服务收到消息类型为7的消息时的"真正的"消息处理函数
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

local coroutine_pool = setmetatable({}, { __mode = "kv" })
--co_create 是从协程池找到空闲的协程来执行这个函数，没有空闲的协程则创建。
local function co_create(f)
	local co = table.remove(coroutine_pool)-- 从协程池取出一个协程
	if co == nil then -- 如果没有可用的协程
		co = coroutine.create(function(...) -- 创建新的协程
			f(...)	-- 当调用coroutine.resume时，执行函数f
			while true do
				f = nil 	-- 将函数置空
				coroutine_pool[#coroutine_pool+1] = co-- 协程执行完后，回收协程
				f = coroutine_yield "EXIT" -- a. yield 第一次获取函数   
				f(coroutine_yield()) -- b. yield 第二次获取函数参数，然后执行函数f 
			end
		end)
	else
		-- resume 第一次让协程取到函数，就是 a点  
        -- 之后再 resume 第二次传入参数，并执行函数，就是b点  
		coroutine_resume(co, f)  
	end
	return co
end
-- 用来唤醒 mtask.wakeup 函数中的参数(协程)
local function dispatch_wakeup()
    local co = table.remove(wakeup_queue,1)
    if co then
        local session = sleep_session[co]
        if session then
        	-- 因为这里有可能会提前wakeup，所以将对应的 session 的协程置为 "BREAK" 
        	-- 这样当定时器超时后，框架会知道这个sleep早就被唤醒了，不需要再处理了
            session_id_coroutine[session] = "BREAK"
            -- 一般会唤醒 mtask.sleep 中的 local succ, ret = coroutine_yield("SLEEP", session) 的执行
            return suspend(co, coroutine_resume(co, false, "BREAK"))
        end
    end
end
-- 将源服务的引用计数减1
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
		-- 当协程错误发生时，或mtask.sleep被mtask.wakeup提前唤醒时
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
	-- 调用mtask.call会触发此处执行
	if command == "CALL" then
		session_id_coroutine[param] = co-- 以session为key记录协程
	-- 调用mtask.sleep后会触发此处执行
	elseif command == "SLEEP" then
		session_id_coroutine[param] = co-- 这里的param是session
		sleep_session[co] = param
	-- 调用mtask.ret后会触发此处执行
	elseif command == "RETURN" then
		local co_session = session_coroutine_id[co]
        if co_session == 0 then
            if size ~= nil then
                c.trash(param, size)
            end
            return suspend(co, coroutine_resume(co, false))	-- send don't need ret
        end

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
		--coroutine_resume会恢复处理函数中的协程执行(会从mtask.ret中的coroutine_yield("RETURN", msg, sz)处返回)，到这里处理函数执行完毕了，即co_create中的f函数执行完毕了
		return suspend(co, coroutine_resume(co, ret))
	-- 可看例子:testresponse.lua
	elseif command == "RESPONSE" then
		local co_session = session_coroutine_id[co]
		local co_address = session_coroutine_address[co]
		if session_response[co] then
			error(debug.traceback(co))
		end
		local f = param -- 默认为mtask.pack
		local function response(ok, ...)
			if ok == "TEST" then
				if dead_service[co_address] then
                    release_watching(co_address)
					unresponse[response] = nil
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
            -- do not response when session == 0 (send)
            if co_session ~= 0 and not dead_service[co_address] then
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
		session_response[co] = true
		unresponse[response] = true
		-- 恢复 mtask.response 中的 coroutine_yield("RESPONSE", pack) 执行，即让 mtask.response 返回
		return suspend(co, coroutine_resume(co, response))
	-- 执行到 co_create 中的f = coroutine_yield "EXIT"会触发此处的执行，到这里对于收到消息的一方来说这次消息完全处理完毕
	elseif command == "EXIT" then
		-- coroutine exit
		local address = session_coroutine_address[co]
		release_watching(address)
		session_coroutine_id[co] = nil
		session_coroutine_address[co] = nil
		session_response[co] = nil
	-- 调用 mtask.exit 会触发此处执行
	elseif command == "QUIT" then
		-- service exit
		return
    elseif command == "USER" then
    -- See mtask.coutine for detail
        error("Call mtask.coroutine.yield out of mtask.coroutine.resume\n" .. debug.traceback(co))
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

-- 向框架注册一个定时器，并得到一个session，从定时器发过来的消息源地址是 0
function mtask.timeout(ti, func)
	local session = c.intcommand("TIMEOUT",ti)
	assert(session)
	local co = co_create(func)
	assert(session_id_coroutine[session] == nil)
	session_id_coroutine[session] = co
end
--阻塞 API
--将当前 coroutine 挂起 ti 个单位时间。一个单位是 1/100 秒。
--它是向框架注册一个定时器实现的。框架会在 ti 时间后，发送一个定时器消息来唤醒这个 coroutine
--它的返回值会告诉你是时间到了，还是被 mtask.wakeup 唤醒 （返回 "BREAK"）

-- 将当前协程挂起ti时间，实际上也是向框架注册一个定时器，区别是挂起的时间可以被mtask.wakeup"打断"
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
-- 把当前 coroutine 挂起。必须由 mtask.wakeup 唤醒
function mtask.wait(co)
	-- 由于不需要向框架注册一个定时器，但是挂起的协程需要一个session，
	-- 所以通过 c.genid生成， c.genid不会把任何消息压入消息队列中
	local session = c.genid() 
	local ret, msg = coroutine_yield("SLEEP", session)
    co = co  or  coroutine.running()
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
-- 用来查询一个 . 开头的名字对应的地址。它是一个非阻塞 API ，不可以查询跨节点的全局名字。
-- 返回一个带冒号的16进制地址
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
mtask.now = c.now

local starttime
--返回 mtask 节点进程启动的 UTC 时间，以秒为单位
function mtask.starttime()
    if not starttime then
        starttime = c.intcommand("STARTTIME")
    end
    return starttime
end
--返回以秒为单位（精度为小数点后两位）的 UTC 时间。
function mtask.time()
    return mtask.now()/100 + (starttime or mtask.starttime())
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
			c.send(address, mtask.PTYPE_ERROR, session, "")
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
		c.send(address, mtask.PTYPE_ERROR, 0, "")
	end
	c.command("EXIT")
	-- quit service
	coroutine_yield "QUIT"
end
--获取mtask 环境变量
function mtask.getenv(key)
    return (c.command("GETENV",key))
end
--设置mtask 环境变量
function mtask.setenv(key, value)
	c.command("SETENV",key .. " " ..value)
end
--非阻塞 API ，发送完消息后，coroutine 会继续向下运行，这期间服务不会重入
--把一条类别为 typename 的消息发送给 address 
--它会先经过事先注册的 pack 函数打包 ... 的内容

-- 调用此接口发送消息(不需要返回值)
function mtask.send(addr, typename, ...)
	local p = proto[typename]
	--由于mtask.send是不需要返回值的，所以就不需要记录session，所以为0即可
	return c.send(addr, p.id, 0 , p.pack(...))
end

function mtask.rawsend(addr, typename, msg, sz)
    local p = proto[typename]
    return c.send(addr, p.id, 0 , msg, sz)
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
	-- 会让出到 raw_dispatch_message 中的第二个suspend函数中，
	-- 即执行:suspend(true, "CALL", session)
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

-- 调用此接口发送消息(需要返回值)
function mtask.call(addr, typename, ...)
	local p = proto[typename]
	local session = c.send(addr, p.id , nil , p.pack(...))-- 发送消息
	-- 由于mtask.call是需要返回值的，所以c.send的第三个参数表示由框架自动分配一个session，
	-- 以便返回时根据相应的session找到对应的协程进行处理
	if session == nil then
		error("call to invalid address " .. mtask.address(addr))
	end
	return p.unpack(yield_call(addr, session))-- 阻塞等待返回值
end
--和 mtask.call 功能类似（也是阻塞 API）。
--但发送时不经过 pack 打包流程，收到回应后，也不走 unpack 流程。
function mtask.rawcall(addr, typename, msg, sz)
	local p = proto[typename]
	local session = assert(c.send(addr, p.id , nil , msg, sz), "call to invalid address")
	return yield_call(addr, session)
end
--非阻塞 API, 回应一个消息,
--在同一个消息处理的 coroutine 中只可以被调用一次，多次调用会触发异常
--有时候，你需要挂起一个请求，等将来时机满足，再回应它.
--而回应的时候已经在别的 coroutine 中了。
--针对这种情况，你可以调用 mtask.response(mtask.pack) 获得一个闭包，以后调用这个闭包即可把回应消息发回。
--这里的参数 mtask.pack 是可选的，你可以传入其它打包函数，默认即是 mtask.pack 。

-- 一般用来返回消息给主动调用mtask.call的服务
function mtask.ret(msg, sz)
	msg = msg or ""
	-- 会让出到raw_dispatch_message函数的else分支中，参数给suspend,
	-- 就成为:suspend(co, true, "RETURN", msg, sz)
	return coroutine_yield("RETURN", msg, sz)
end
--非阻塞 API,返回的闭包可用于延迟回应。
--调用它时，第一个参数通常是 true 表示是一个正常的回应，之后的参数是需要回应的数据。
--如果是 false ，则给请求者抛出一个异常。它的返回值表示回应的地址是否还有效。
--如果你仅仅想知道回应地址的有效性，那么可以在第一个参数传入 "TEST" 用于检测。

-- 与 mtask.ret 有异曲同工之用，区别是调用者可以选择何时进行返回
-- 区别在于: 1. 可以提供打包函数(默认为mtask.pack) 2.调用者需要调用它返回的调用值(一个函数)并提供参数
-- 共同之处在于一般都是在消息处理函数中进行调用
function mtask.response(pack)
	pack = pack or mtask.pack
	-- 一般会让出到 raw_dispatch_message 的else分支的 
	-- suspend(co, coroutine_resume(co, session,source, p.unpack(msg,sz))) 处
	return coroutine_yield("RESPONSE", pack)
end

function mtask.retpack(...)
	return mtask.ret(mtask.pack(...))
end
-- 唤醒一个被 mtask.sleep 或 mtask.wait 挂起的 coroutine 。可以保证次序
-- 将wakeup_session中的某个协程置为true，由 dispatch_wakeup 从中取出进行处理
function mtask.wakeup(co)
    if sleep_session[co] then
        table.insert(wakeup_queue, co)
        return true
    end
end
--Lua API 消息分发注册特定类消息的处理函数。大多数程序会注册 lua 类消息的处理函数
--dispatch 函数会在收到每条类别对应的消息时被回调。
--消息先经过 unpack 函数，返回值被传入 dispatch 。
--每条消息的处理都工作在一个独立的 coroutine 中，看起来以多线程方式工作。
--但记住，在同一个 lua 虚拟机（同一个 lua 服务）中，永远不可能出现多线程并发的情况

-- 将func赋值给proto[typename].dispatch， 这里的func就是真正的消息处理函数
-- func = function(session, source, cmd, subcmd, ...)
function mtask.dispatch(typename, func)
	local p = proto[typename]
	if func then  --lua类型的消息一般走这里
		local ret = p.dispatch
		p.dispatch = func -- 设置协议的处理函数  
		return ret
	else
		return p and p.dispatch
	end
end
-- 仅仅做下日志处理，并抛出异常，但是永不返回
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

-- 创建一个协程，协程执行func(...)函数，将协程加入fork_queue，
-- 等待 mtask.dispatch_message 的调用
function mtask.fork(func,...)
	local args = { ... }
	local co = co_create(function()
        	func(table.unpack(args,1,args.n))
	end)
	table.insert(fork_queue, co)
	return co
end
-- 所有lua服务的消息处理函数(从定时器发过来的消息源地址(source)是 0) 这里的msg就是特定的数据结构体
-- 这里的第一个参数 prototype 是同时支持 字符串与枚举类型索引的
-- 关于proto[typename] 可以看作是对数据的封装，方便不同服务间、不同节点间，以及前后端的数据通讯，
-- 不需要手动封包解包。默认支持lua/response/error这3个协议，还有log和debug协议，除了这几个，其他要自己调用mtask.register_protocol 注册
local function raw_dispatch_message(prototype, msg, sz, session, source)
	-- mtask.PTYPE_RESPONSE = 1, read mtask.h
	if prototype == 1 then-- 处理远端发送过来的返回值
		local co = session_id_coroutine[session]
		if co == "BREAK" then
			session_id_coroutine[session] = nil
		elseif co == nil then
			unknown_response(session, source, msg, sz)
		else
			session_id_coroutine[session] = nil
			-- 唤醒yield_call中的coroutine_yield("CALL", session)
			suspend(co, coroutine.resume(co, true, msg, sz))
		end
	else
		local p = proto[prototype]
		if p == nil then
			-- 如果是需要返回值的，那么告诉源服务，说"我对你来说是dead_service不要再发过来了"
			if session ~= 0 then
				c.send(source, mtask.PTYPE_ERROR, session, "")
			else
				unknown_request(session, source, msg, sz, prototype)
			end
			return
		end
		local f = p.dispatch -- 找到dispatch函数  
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
			suspend(co, coroutine_resume(co, session,source, p.unpack(msg,sz)))
		elseif session ~= 0 then
			c.send(source, mtask.PTYPE_ERROR, session, "")
		else
			unknown_request(session, source, msg, sz, proto[prototype].name)
		end
	end
end
-- lua服务的消息处理函数的最外层
-- 首先是将msg交由raw_dispatch_message作分发，然后开始处理fork_queue中缓存的fork协程
function mtask.dispatch_message(...)
	local succ, err = pcall(raw_dispatch_message,...)
	while true do
		local key,co = next(fork_queue)
		if co == nil then
			break
		end
		fork_queue[key] = nil
		--重点理解:
		local fork_succ, fork_err = pcall(suspend,co,coroutine_resume(co))
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
	-- .launcher 服务就是 launcher.lua
	return mtask.call(".launcher", "lua" , "LAUNCH", "snlua", name, ...)
end
-- 启动唯一的一份Lua 服务 （全局唯一）.service 为 service_mgr
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
-- 返回地址的字符串形式,以冒号开头
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

mtask.error = c.error


----- register protocol  默认的三种类型
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
        table.insert(init_func, f)
		if name then
            assert(type(name) == "string")
			assert(init_func[name] == nil)
			init_func[name] = f
		end
	end
end

local function init_all()
    local funcs = init_func
    init_func = nil
    if funcs then
        for _,f in ipairs(funcs) do
            f()
        end
    end
end

local function ret(f, ...)
    f()
    return ...
end

local function init_template(start, ...)
    init_all()
    init_func = {}
    return ret(init_all, start(...))
end

function mtask.pcall(start, ...)
	return xpcall(init_template, debug.traceback, start, ...)
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
    return (c.intcommand("STAT", "endless") == 1)
end

function mtask.mqlen()
    return c.intcommand("STAT", "mqlen")
end

function mtask.stat(what)
    return c.intcommand("STAT", what)
end
-- 返回当前服务挂起的任务数
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

function mtask.memlimit(bytes)
    debug.getregistry().memlimit = bytes
    mtask.memlimit = nil	-- set only once
end

-- Inject internal debug framework
local debug = require "mtask.debug"
debug.init(mtask, {
   dispatch = mtask.dispatch_message,
   suspend = suspend,
})


return mtask
