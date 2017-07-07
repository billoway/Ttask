local mtask = require "mtask"
local sharedata = require "mtask.sharedata"

local mode = ...

if mode == "host" then

mtask.start(function()
	mtask.error("new foobar")
	sharedata.new("foobar", { a=1, b= { "hello",  "world" } })

	mtask.fork(function()
		mtask.sleep(200)	-- sleep 2s
		mtask.error("update foobar a = 2")
		sharedata.update("foobar", { a =2 })
		mtask.sleep(200)	-- sleep 2s
		mtask.error("update foobar a = 3")
		sharedata.update("foobar", { a = 3, b = { "change" } })
		mtask.sleep(100)
		mtask.error("delete foobar")
		sharedata.delete "foobar"
	end)
end)

else


mtask.start(function()
	mtask.newservice(SERVICE_NAME, "host")

	local obj = sharedata.query "foobar"

	local b = obj.b
	mtask.error(string.format("a=%d", obj.a))

	for k,v in ipairs(b) do
		mtask.error(string.format("b[%d]=%s", k,v))
	end

	-- test lua serialization
	local s = mtask.packstring(obj)
	local nobj = mtask.unpack(s)
	for k,v in pairs(nobj) do
		mtask.error(string.format("nobj[%s]=%s", k,v))
	end
	for k,v in ipairs(nobj.b) do
		mtask.error(string.format("nobj.b[%d]=%s", k,v))
	end

	for i = 1, 5 do
		mtask.sleep(100)
		mtask.error("second " ..i)
		for k,v in pairs(obj) do
			mtask.error(string.format("%s = %s", k , tostring(v)))
		end
	end

	local ok, err = pcall(function()
		local tmp = { b[1], b[2] }	-- b is invalid , so pcall should failed
	end)

	if not ok then
		mtask.error(err)
	end

	-- obj. b is not the same with local b
	for k,v in ipairs(obj.b) do
		mtask.error(string.format("b[%d] = %s", k , tostring(v)))
	end

	collectgarbage()
	mtask.error("sleep")
	mtask.sleep(100)
	b = nil
	collectgarbage()
	mtask.error("sleep")
	mtask.sleep(100)

	mtask.exit()
end)

end
