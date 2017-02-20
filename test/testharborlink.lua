local mtask = require "mtask"
local harbor = require "mtask.harbor"

mtask.start(function()
	print("wait for harbor 2")
	print("run mtask examples/config_log please")
	harbor.connect(2)
	print("harbor 2 connected")
	print("LOG =", mtask.address(harbor.queryname "LOG"))
	harbor.link(2)
	print("disconnected")
end)
