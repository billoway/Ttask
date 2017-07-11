local mtask = require "mtask"
local sc = require "mtask.socketchannel"
local socket = require "mtask.socket"
local cluster = require "mtask.cluster.core"

local config_name = mtask.getenv "cluster"
local node_address = {}
local node_session = {}
local command = {}

local function read_response(sock)
	-- sock:read(2)为读取前两个字节 socket.header(sock:read(2))为得到前两个字节表示的 number 类型的值
	local sz = socket.header(sock:read(2))
	local msg = sock:read(sz)
	return cluster.unpackresponse(msg)	-- session, ok, data, padding
end

local function open_channel(t, key)
	local host, port = string.match(node_address[key], "([^:]+):(.*)$")
	local c = sc.channel {
		host = host,
		port = tonumber(port),
		response = read_response,
		nodelay = true,
	}
	assert(c:connect(true))
	t[key] = c
	return c
end

local node_channel = setmetatable({}, { __index = open_channel })

local function loadconfig(tmp)
	if tmp == nil then
		tmp = {}
		if config_name then
			local f = assert(io.open(config_name))
			local source = f:read "*a"
			f:close()
			assert(load(source, "@"..config_name, "t", tmp))()
		end
	end
	for name,address in pairs(tmp) do
		assert(type(address) == "string")
		if node_address[name] ~= address then
			-- address changed
			if rawget(node_channel, name) then
				node_channel[name] = nil	-- reset connection
			end
			node_address[name] = address
		end
	end
end

function command.reload(source, config)
	loadconfig(config)
	mtask.ret(mtask.pack(nil))
end

function command.listen(source, addr, port)
	local gate = mtask.newservice("gate")
	if port == nil then
		addr, port = string.match(node_address[addr], "([^:]+):(.*)$")
	end
	mtask.call(gate, "lua", "open", { address = addr, port = port })
	mtask.ret(mtask.pack(nil))
end

local function send_request(source, node, addr, msg, sz)
	local session = node_session[node] or 1
	-- msg is a local pointer, cluster.packrequest will free it
	-- request 为前面10个字节[(sz+9)、0(0x80, 0x81)、addr(int32)、session(int32)]加上msg组成的字符串
	-- session 会自增1
	local request, new_session, padding = cluster.packrequest(addr, session, msg, sz)
	node_session[node] = new_session

	-- node_channel[node] may yield or throw error
	local c = node_channel[node]

	return c:request(request, session, padding)
end

function command.req(...)
	local ok, msg, sz = pcall(send_request, ...)
	if ok then
		if type(msg) == "table" then
			mtask.ret(cluster.concat(msg))
		else
			mtask.ret(msg)
		end
	else
		mtask.error(msg)
		mtask.response()(false)
	end
end

function command.push(source, node, addr, msg, sz)
	local session = node_session[node] or 1
	local request, new_session, padding = cluster.packpush(addr, session, msg, sz)
	if padding then	-- is multi push
		node_session[node] = new_session
	end

	-- node_channel[node] may yield or throw error
	local c = node_channel[node]

	c:request(request, nil, padding)

	-- notice: push may fail where the channel is disconnected or broken.
end

local proxy = {}

function command.proxy(source, node, name)
	local fullname = node .. "." .. name
	if proxy[fullname] == nil then
		proxy[fullname] = mtask.newservice("clusterproxy", node, name)
	end
	mtask.ret(mtask.pack(proxy[fullname]))
end

local register_name = {}

function command.register(source, name, addr)
	assert(register_name[name] == nil)
	addr = addr or source
	local old_name = register_name[addr]
	if old_name then
		register_name[old_name] = nil
	end
	register_name[addr] = name
	register_name[name] = addr
	mtask.ret(nil)
	mtask.error(string.format("Register [%s] :%08x", name, addr))
end

local large_request = {}
-- 供主动监听的一方接收 gate 服务发过来的消息使用
function command.socket(source, subcmd, fd, msg)
	if subcmd == "data" then
		local sz
		local addr, session, msg, padding, is_push = cluster.unpackrequest(msg)
		if padding then
			local req = large_request[session] or { addr = addr , is_push = is_push }
			large_request[session] = req
			table.insert(req, msg)
			return
		else
			local req = large_request[session]
			if req then
				large_request[session] = nil
				table.insert(req, msg)
				msg,sz = cluster.concat(req)
				addr = req.addr
				is_push = req.is_push
			end
			if not msg then
				local response = cluster.packresponse(session, false, "Invalid large req")
				socket.write(fd, response)
				return
			end
		end
		local ok, response
		if addr == 0 then-- 如果为 0 代表是查询地址
			local name = mtask.unpack(msg, sz)
			local addr = register_name[name]
			if addr then
				ok = true
				msg, sz = mtask.pack(addr)
			else
				ok = false
				msg = "name not found"
			end
		elseif is_push then
			mtask.rawsend(addr, "lua", msg, sz)
			return	-- no response
		else
			ok , msg, sz = pcall(mtask.rawcall, addr, "lua", msg, sz)
		end
		if ok then
			response = cluster.packresponse(session, true, msg, sz)
			if type(response) == "table" then
				for _, v in ipairs(response) do
					socket.lwrite(fd, v)
				end
			else
				socket.write(fd, response)
			end
		else
			response = cluster.packresponse(session, false, msg)
			socket.write(fd, response)
		end
	elseif subcmd == "open" then
		mtask.error(string.format("socket accept from %s", msg))
		mtask.call(source, "lua", "accept", fd)
	else
		large_request = {}
		mtask.error(string.format("socket %s %d : %s", subcmd, fd, msg))
	end
end

mtask.start(function()
	print("clusterd.lua  start calling")
	loadconfig()
	mtask.dispatch("lua", function(session , source, cmd, ...)
		local f = assert(command[cmd])
		f(source, ...)
	end)
end)
