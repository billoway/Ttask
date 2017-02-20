local mtask = require "mtask"
local httpc = require "http.httpc"
local express = require "web.express"

mtask.start(function()
	-- body
	print("web http server start....")
	local web = express.app(8001,{
		web_root = "./mtask_web/www",
		thread = 2,
		static_regular = ".js|.html|.css|.pb|.png"
		})
	--web:use(".","/test/auth/tocken")
	web:listen()
	local header = {}
	local status, body = httpc.get("127.0.0.1:8001", "/test/user/index?tocken=1", {})
		print("222========",status,body)

	local status, body1 = httpc.get("127.0.0.1:8001", "/test.html", {})
	print("333========",status,body1)
	mtask.sleep(5000)
	mtask.exit()
end)