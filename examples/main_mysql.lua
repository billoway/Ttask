local mtask = require "mtask"


mtask.start(function()
	print("Main Server start")
	local console = mtask.newservice("testmysql")
	
	print("Main Server exit")
	mtask.exit()
end)
