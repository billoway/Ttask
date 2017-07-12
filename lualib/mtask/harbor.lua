local mtask = require "mtask"

local harbor = {}
-- 注册一个全局名字
function harbor.globalname(name, handle)
	handle = handle or mtask.self()
	mtask.send(".cslave", "lua", "REGISTER", name, handle)
end
-- 阻塞的查询全局名字或本地名字对应的服务地址，如果查不到则一直等到这个名字注册上来
function harbor.queryname(name)
	return mtask.call(".cslave", "lua", "QUERYNAME", name)
end
-- 阻塞监控 某个 slave 是否断开，当slave断开，则返回
function harbor.link(id)
	mtask.call(".cslave", "lua", "LINK", id)
end
-- 阻塞的等待一个 slave连接上来 ，
-- 如果slave已连接，则直接返回，如果未连接，则等连接连上来后再返回
function harbor.connect(id)
	mtask.call(".cslave", "lua", "CONNECT", id)
end
-- 阻塞的监控 master，当 master 断开时才返回
function harbor.linkmaster()
	mtask.call(".cslave", "lua", "LINKMASTER")
end

return harbor
