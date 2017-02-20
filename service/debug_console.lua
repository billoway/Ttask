local mtask = require "mtask"
local codecache = require "mtask.codecache"
local core = require "mtask.core"
local socket = require "socket"
local snax = require "snax"

local port = tonumber(...)
local COMMAND = {}

local function format_table(t)
	local index = {}
	for k in pairs(t) do
		table.insert(index, k)
	end
	table.sort(index)
	local result = {}
	for _,v in ipairs(index) do
		table.insert(result, string.format("%s:%s",v,tostring(t[v])))
	end
	return table.concat(result,"\t")
end

local function dump_line(print, key, value)
	if type(value) == "table" then
		print(key, format_table(value))
	else
		print(key,tostring(value))
	end
end

local function dump_list(print, list)
	local index = {}
	for k in pairs(list) do
		table.insert(index, k)
	end
	table.sort(index)
	for _,v in ipairs(index) do
		dump_line(print, v, list[v])
	end
	print("OK")
end

local function split_cmdline(cmdline)
	local split = {}
	for i in string.gmatch(cmdline, "%S+") do
		table.insert(split,i)
	end
	return split
end

local function docmd(cmdline, print, fd)
	local split = split_cmdline(cmdline)
	local command = split[1]
	if command == "debug" then
		table.insert(split, fd)
	end
	local cmd = COMMAND[command]
	local ok, list
	if cmd then
		ok, list = pcall(cmd, select(2,table.unpack(split)))
	else
		print("Invalid command, type help for command list")
	end

	if ok then
		if list then
			if type(list) == "string" then
				print(list)
			else
				dump_list(print, list)
			end
		else
			print("OK")
		end
	else
		print("Error:", list)
	end
end

local function console_main_loop(stdin, print)
	socket.lock(stdin)
	print("Welcome to mtask console")
	while true do
		local cmdline = socket.readline(stdin, "\n")
		if not cmdline then
			break
		end
		if cmdline ~= "" then
			docmd(cmdline, print, stdin)
		end
	end
	socket.unlock(stdin)
end

mtask.start(function()
	local listen_socket = socket.listen ("127.0.0.1", port)
	mtask.error("Start debug console at 127.0.0.1 " .. port)
	socket.start(listen_socket , function(id, addr)
		local function print(...)
			local t = { ... }
			for k,v in ipairs(t) do
				t[k] = tostring(v)
			end
			socket.write(id, table.concat(t,"\t"))
			socket.write(id, "\n")
		end
		socket.start(id)
		mtask.fork(console_main_loop, id , print)
	end)
end)

function COMMAND.help()
	return {
		help = "This help message",
		list = "List all the service",
		stat = "Dump all stats",
		info = "Info address : get service infomation",
		exit = "exit address : kill a lua service",
		kill = "kill address : kill service",
		mem = "mem : show memory status",
		gc = "gc : force every lua service do garbage collect",
		start = "lanuch a new lua service",
		snax = "lanuch a new snax service",
		clearcache = "clear lua code cache",
		service = "List unique service",
		task = "task address : show service task detail",
		inject = "inject address luascript.lua",
		logon = "logon address",
		logoff = "logoff address",
		log = "launch a new lua service with log",
		debug = "debug address : debug a lua service",
		signal = "signal address sig",
	}
end

function COMMAND.clearcache()
	codecache.clear()
end

function COMMAND.start(...)
	local ok, addr = pcall(mtask.newservice, ...)
	if ok then
		return { [mtask.address(addr)] = ... }
	else
		return "Failed"
	end
end

function COMMAND.log(...)
	local ok, addr = pcall(mtask.call, ".launcher", "lua", "LOGLAUNCH", "snlua", ...)
	if ok then
		return { [mtask.address(addr)] = ... }
	else
		return "Failed"
	end
end

function COMMAND.snax(...)
	local ok, s = pcall(snax.newservice, ...)
	if ok then
		local addr = s.handle
		return { [mtask.address(addr)] = ... }
	else
		return "Failed"
	end
end

function COMMAND.service()
	return mtask.call("SERVICE", "lua", "LIST")
end

local function adjust_address(address)
	if address:sub(1,1) ~= ":" then
		address = assert(tonumber("0x" .. address), "Need an address") | (mtask.harbor(mtask.self()) << 24)
	end
	return address
end

function COMMAND.list()
	return mtask.call(".launcher", "lua", "LIST")
end

function COMMAND.stat()
	return mtask.call(".launcher", "lua", "STAT")
end

function COMMAND.mem()
	return mtask.call(".launcher", "lua", "MEM")
end

function COMMAND.kill(address)
	return mtask.call(".launcher", "lua", "KILL", address)
end

function COMMAND.gc()
	return mtask.call(".launcher", "lua", "GC")
end

function COMMAND.exit(address)
	mtask.send(adjust_address(address), "debug", "EXIT")
end

function COMMAND.inject(address, filename)
	address = adjust_address(address)
	local f = io.open(filename, "rb")
	if not f then
		return "Can't open " .. filename
	end
	local source = f:read "*a"
	f:close()
	return mtask.call(address, "debug", "RUN", source, filename)
end

function COMMAND.task(address)
	address = adjust_address(address)
	return mtask.call(address,"debug","TASK")
end

function COMMAND.info(address)
	address = adjust_address(address)
	return mtask.call(address,"debug","INFO")
end

function COMMAND.debug(address, fd)
	address = adjust_address(address)
	local agent = mtask.newservice "debug_agent"
	local stop
	mtask.fork(function()
		repeat
			local cmdline = socket.readline(fd, "\n")
            cmdline = cmdline:gsub("(.*)\r$", "%1")
			if not cmdline then
				mtask.send(agent, "lua", "cmd", "cont")
				break
			end
			mtask.send(agent, "lua", "cmd", cmdline)
		until stop or cmdline == "cont"
	end)
	mtask.call(agent, "lua", "start", address, fd)
	stop = true
end

function COMMAND.logon(address)
	address = adjust_address(address)
	core.command("LOGON", mtask.address(address))
end

function COMMAND.logoff(address)
	address = adjust_address(address)
	core.command("LOGOFF", mtask.address(address))
end

function COMMAND.signal(address, sig)
	address = mtask.address(adjust_address(address))
	if sig then
		core.command("SIGNAL", string.format("%s %d",address,sig))
	else
		core.command("SIGNAL", address)
	end
end
