local mtask = require "mtask"
local netpack = require "netpack"
local socket = require "socket"
local sproto = require "sproto"
local sprotoloader = require "sprotoloader"

local WATCHDOG
local host
local send_request

local CMD = {}
local REQUEST = {}
local client_fd

function REQUEST:get()
	print("get", self.what)
	local r = mtask.call("SIMPLEDB", "lua", "get", self.what)
	return { result = r }
end

function REQUEST:set()
	print("set", self.what, self.value)
	local r = mtask.call("SIMPLEDB", "lua", "set", self.what, self.value)
end

function REQUEST:handshake()
	return { msg = "Welcome to mtask, I will send heartbeat every 5 sec." }
end

function REQUEST:quit()
	mtask.call(WATCHDOG, "lua", "close", client_fd)
end

local function request(name, args, response)
	local f = assert(REQUEST[name])
	local r = f(args)
	if response then
		return response(r)
	end
end

local function send_package(pack)
	local package = string.pack(">s2", pack)
	socket.write(client_fd, package)
end

mtask.register_protocol {
	name = "client",
	id = mtask.PTYPE_CLIENT,
	unpack = function (msg, sz)
		return host:dispatch(msg, sz)
	end,
	dispatch = function (_, _, type, ...)
		if type == "REQUEST" then
			local ok, result  = pcall(request, ...)
			if ok then
				if result then
					send_package(result)
				end
			else
				mtask.error(result)
			end
		else
			assert(type == "RESPONSE")
			error "This example doesn't support request client"
		end
	end
}

function CMD.start(conf)
	local fd = conf.client
	local gate = conf.gate
	WATCHDOG = conf.watchdog
	-- slot 1,2 set at main.lua
	host = sprotoloader.load(1):host "package"
	send_request = host:attach(sprotoloader.load(2))
	mtask.fork(function()
		while true do
			send_package(send_request "heartbeat")
			mtask.sleep(500)
		end
	end)

	client_fd = fd
	mtask.call(gate, "lua", "forward", fd)
end

function CMD.disconnect()
	-- todo: do something before exit
	mtask.exit()
end

mtask.start(function()
	mtask.dispatch("lua", function(_,_, command, ...)
		local f = CMD[command]
		mtask.ret(mtask.pack(f(...)))
	end)
end)
