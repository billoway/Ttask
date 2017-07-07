local mtask = require "mtask"
local service = require "mtask.service"
local core = require "mtask.datasheet.core"

local datasheet_svr

mtask.init(function()
	datasheet_svr = service.query "datasheet"
end)

local datasheet = {}
local sheets = setmetatable({}, {
	__gc = function(t)
		for _,v in pairs(t) do
			mtask.send(datasheet_svr, "lua", "release", v.handle)
		end
	end,
})

local function querysheet(name)
	return mtask.call(datasheet_svr, "lua", "query", name)
end

local function updateobject(name)
	local t = sheets[name]
	if not t.object then
		t.object = core.new(t.handle)
	end
	local function monitor()
		local handle = t.handle
		local newhandle = mtask.call(datasheet_svr, "lua", "monitor", handle)
		core.update(t.object, newhandle)
		t.handle = newhandle
		mtask.send(datasheet_svr, "lua", "release", handle)
		mtask.fork(monitor)
	end
	mtask.fork(monitor)
end

function datasheet.query(name)
	local t = sheets[name]
	if not t then
		t = {}
		sheets[name] = t
	end
	if t.error then
		error(t.error)
	end
	if t.object then
		return t.object
	end
	if t.queue then
		local co = coroutine.running()
		table.insert(t.queue, co)
		mtask.wait(co)
	else
		t.queue = {}	-- create wait queue for other query
		local ok, handle = pcall(querysheet, name)
		if ok then
			t.handle = handle
			updateobject(name)
		else
			t.error = handle
		end
		local q = t.queue
		t.queue = nil
		for _, co in ipairs(q) do
			mtask.wakeup(co)
		end
	end
	if t.error then
		error(t.error)
	end
	return t.object
end

return datasheet
