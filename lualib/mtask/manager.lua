local mtask = require "mtask"
local c = require "mtask.core"

--用于启动一个 C 模块的服务。由于 mtask 主要用 lua 编写服务，所以它用的并不多。
--注意：同一段 lua 脚本可以作为一个 lua 服务启动多次，同一个 C 模块也可以作为 C 服务启动多次。
--服务的地址是区分运行时不同服务的唯一标识。
--如果你想编写一个服务，在系统中只存在一份，UniqueService 
function mtask.launch(...)
	local addr = c.command("LAUNCH", table.concat({...}," "))-- 调用 lualib-src 下的 lua-mtask 模块
	if addr then
		return tonumber("0x" .. string.sub(addr , 2))
	end
end
--可以用来强制关闭别的服务,但强烈不推荐这样做。因为对象会在任意一条消息处理完毕后，毫无征兆的退出。
--所以推荐的做法是，发送一条消息，让对方自己善后以及调用 mtask.exit
function mtask.kill(name)
	if type(name) == "number" then
		mtask.send(".launcher","lua","REMOVE",name, true)
		name = mtask.address(name)
	end
	c.command("KILL",name)
end
--退出 mtask 进程
function mtask.abort()
	c.command("ABORT")
end
-- 主要是看名字是不是以"."开头,如果不是"."开头，则注册一个整个mtask网络都有效的字符串地址
local function globalname(name, handle)
	local c = string.sub(name,1,1)
	assert(c ~= ':')  --字符串地址不能是冒号开头
	if c == '.' then
		return false
	end
	-- 字符串地址长度不能超过16个字符
	assert(#name <= 16)	-- GLOBALNAME_LENGTH is 16, defined in mtask_harbor.h
	assert(tonumber(name) == nil)	-- global name can't be number

	local harbor = require "mtask.harbor"

	harbor.globalname(name, handle)

	return true
end
--给自身地址(服务)注册一个名字  mtask.register(name) 等价于 mtask.name(name, mtask.self())
function mtask.register(name)
	if not globalname(name) then --以"."开头都返回false
		c.command("REG", name)
	end
end
--为一个地址(服务)命名
function mtask.name(name, handle)
	if not globalname(name, handle) then --以"."开头都返回false
		c.command("NAME", name .. " " .. mtask.address(handle))
	end
end

local dispatch_message = mtask.dispatch_message
--将本服务实现为消息转发器，对一类消息进行转发
--与 mtask.start 不同，mtask.forward_type需要多传递一张表，表示哪些类的消息不需要
--框架调用 mtask_free。
function mtask.forward_type(map, start_func)
	c.callback(function(ptype, msg, sz, ...)
		local prototype = map[ptype]
		if prototype then
			dispatch_message(prototype, msg, sz, ...)
		else
			local ok, err = pcall(dispatch_message, ptype, msg, sz, ...)
			c.trash(msg, sz)
			if not ok then
				error(err)
			end
		end
	end, true)
	mtask.timeout(0, function()
		mtask.init_service(start_func)
	end)
end
--过滤消息再处理:filter 可以将 type, msg, sz, session, source 五个参数先处理过再返回新的 5 个参数。）
function mtask.filter(f ,start_func)
	c.callback(function(...)
		dispatch_message(f(...))
	end)
	mtask.timeout(0, function()
		mtask.init_service(start_func)
	end)
end
--给当前 mtask 进程设置一个全局的服务监控
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
