local mtask = require "mtask"
local snax   = require "snax"
local socket = require "socket"

local function split_cmdline(cmdline)
	local split = {}
	for i in string.gmatch(cmdline, "%S+") do
		table.insert(split,i)
	end
	return split
end

local function console_main_loop()
	local stdin = socket.stdin()
	socket.lock(stdin)
	while true do
		local cmdline = socket.readline(stdin, "\n")
		local split = split_cmdline(cmdline)
		local command = split[1]
		if command == "snax" then
			pcall(snax.newservice, select(2, table.unpack(split)))
		elseif cmdline ~= "" then
			pcall(mtask.newservice, cmdline)
		end
	end
	socket.unlock(stdin)
end

mtask.start(function()
	mtask.fork(console_main_loop)
end)
