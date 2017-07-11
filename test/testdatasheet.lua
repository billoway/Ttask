local mtask = require "mtask"
local builder = require "mtask.datasheet.builder"
local datasheet = require "mtask.datasheet"

local function dump(t, prefix)
	for k,v in pairs(t) do
		print(prefix, k, v)
		if type(v) == "table" then
			dump(v, prefix .. "." .. k)
		end
	end
end

mtask.start(function()
	builder.new("foobar", {a = 1, b = 2 , c = {3} })
	local t = datasheet.query "foobar"
	local c = t.c
	dump(t, "[1]")
	builder.update("foobar", { b = 4, c = { 5 } })
	print("sleep")
	mtask.sleep(100)
	dump(t, "[2]")
	dump(c, "[2.c]")
	builder.update("foobar", { a = 6, c = 7, d = 8 })
	print("sleep")
	mtask.sleep(100)
	dump(t, "[3]")
end)
