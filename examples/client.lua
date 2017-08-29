package.cpath = "luaclib/?.so"
package.path = "lualib/?.lua;examples/?.lua"


if _VERSION ~= "Lua 5.3" then
	error "Use lua 5.3"
end

local socket = require "client.socket"
local proto = require "proto"
local sproto = require "sproto"

local print_r = require "print_r"

local host = sproto.new(proto.s2c):host "package"
print_r(host)
local request = host:attach(sproto.new(proto.c2s))
print("***************")
local fd = assert(socket.connect("127.0.0.1", 8888))

local function send_package(fd, pack)
	print(string.format("send_package  fd=>%s pack=>%s",fd,pack))
	local package = string.pack(">s2", pack)
	print("package =>",package)
	socket.send(fd, package)
end

local function unpack_package(text)

	local size = #text
	if size < 2 then
		return nil, text
	end
	print(string.format("unpack_package text=>%s",text))

	local s = text:byte(1) * 256 + text:byte(2)
	if size < s+2 then
		return nil, text
	end

	return text:sub(3,2+s), text:sub(3+s)
end

local function recv_package(last)
	
	local result
	result, last = unpack_package(last)
	if result then
		return result, last
	end
	local r = socket.recv(fd)
	if not r then
		return nil, last
	end
	if r == "" then
		error "Server closed"
	end
	return unpack_package(last .. r)
end

local session = 0

local function send_request(name, args)
	print(string.format("send_request name=>%s args=>%s",name,args))
	if  type(args) == "table" then
		print_r(args)
	end

	session = session + 1
	local str = request(name, args, session)
	send_package(fd, str)
	print("Request session=>", session)
end

local last = ""

local function print_request(name, args)
	print(string.format("print_request name=>%s args=>%s", name, args))
	if args then
		for k,v in pairs(args) do
			print("k=>",k,"v=>",v)
		end
	end
end

local function print_response(session, args)
	print(string.format("print_response session=>%s args=>%s", session, args))
	if args then
		for k,v in pairs(args) do
			print("k=>",k,"v=>",v)
		end
	end
end

local function print_package(t, ...)
	print("print_package",t, ...)
	if t == "REQUEST" then
		print_request(...)
	else
		assert(t == "RESPONSE")
		print_response(...)
	end
end

local function dispatch_package()
	while true do
		local v
		v, last = recv_package(last)
		if not v then
			break
		end

		print_package(host:dispatch(v))
	end
end

send_request("handshake")
send_request("set", { what = "hello", value = "world" })
send_request("set", { what = "t1", value = "v1" })

while true do
	dispatch_package()
	local cmd = socket.readstdin()

	if cmd then
		local t = {}

		for w in string.gmatch(cmd,"%S+") do
			table.insert(t,w)
		end

		cmd = t[1]
		local k = t[2]
		local v = t[3]
		if cmd == "quit" then
			send_request("quit")
		elseif cmd == "get" then
			send_request("get", { what = k })
		elseif cmd == "set" then
			send_request("set",{what = k,value=v})
		end
	else
		socket.usleep(100)
	end
end
