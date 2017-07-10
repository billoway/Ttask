local mtask = require "mtask"
local memory = require "mtask.memory"

memory.dumpinfo()
--memory.dump()
local info = memory.info()
for k,v in pairs(info) do
	print(string.format(":%08x %gK",k,v/1024))
end

print("Total memory:", memory.total())
print("Total block:", memory.block())

mtask.start(function() 
	print("cmemory.lua start calling")
	mtask.exit() 
	end)
