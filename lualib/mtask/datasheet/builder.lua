local mtask = require "mtask"
local dump = require "mtask.datasheet.dump"
local core = require "mtask.datasheet.core"
local service = require "mtask.service"

local builder = {}

local cache = {}
local dataset = {}
local address

local  unique_id = 0

local function unique_string(str)
 	unique_id = unique_id + 1
	return str .. tostring(unique_id)
end

local function monitor(pointer)
	mtask.fork(function()
		mtask.call(address, "lua", "collect", pointer)
		for k,v in pairs(cache) do
			if v == pointer then
				cache[k] = nil
				return
			end
		end
	end)
end

local function dumpsheet(v)
	if type(v) == "string" then
		return v
	else
		return dump.dump(v)
	end
end

function builder.new(name, v)
	assert(dataset[name] == nil)
	local datastring = unique_string(dumpsheet(v))
	local pointer = core.stringpointer(datastring)
	mtask.call(address, "lua", "update", name, pointer)
	cache[datastring] = pointer
	dataset[name] = datastring
	monitor(pointer)
end

function builder.update(name, v)
	local lastversion = assert(dataset[name])
	local newversion = dumpsheet(v)
	local diff = dump.diff(lastversion, newversion)
	local pointer = core.stringpointer(diff)
	mtask.call(address, "lua", "update", name, pointer)
	cache[diff] = pointer
	local lp = assert(cache[lastversion])
	mtask.send(address, "lua", "release", lp)
	dataset[name] = diff
	monitor(pointer)
end

function builder.compile(v)
	return dump.dump(v)
end

local function datasheet_service()

local mtask = require "mtask"

local datasheet = {}
local handles = {}	-- handle:{ ref:count , name:name , collect:resp }
local dataset = {}	-- name:{ handle:handle, monitor:{monitors queue} }

local function releasehandle(handle)
	local h = handles[handle]
	h.ref = h.ref - 1
	if h.ref == 0 and h.collect then
		h.collect(true)
		h.collect = nil
		handles[handle] = nil
	end
end

-- from builder, create or update handle
function datasheet.update(name, handle)
	local t = dataset[name]
	if not t then
		-- new datasheet
		t = { handle = handle, monitor = {} }
		dataset[name] = t
		handles[handle] = { ref = 1, name = name }
	else
		t.handle = handle
		-- report update to customers
		handles[handle] = { ref = 1 + #t.monitor, name = name }

		for k,v in ipairs(t.monitor) do
			v(true, handle)
			t.monitor[k] = nil
		end
	end
	mtask.ret()
end

-- from customers
function datasheet.query(name)
	local t = assert(dataset[name], "create data first")
	local handle = t.handle
	local h = handles[handle]
	h.ref = h.ref + 1
	mtask.ret(mtask.pack(handle))
end

-- from customers, monitor handle change
function datasheet.monitor(handle)
	local h = assert(handles[handle], "Invalid data handle")
	local t = dataset[h.name]
	if t.handle ~= handle then	-- already changes
		mtask.ret(mtask.pack(t.handle))
	else
		h.ref = h.ref + 1
		table.insert(t.monitor, mtask.response())
	end
end

-- from customers, release handle , ref count - 1
function datasheet.release(handle)
	-- send message, don't ret
	releasehandle(handle)
end

-- from builder, monitor handle release
function datasheet.collect(handle)
	local h = assert(handles[handle], "Invalid data handle")
	if h.ref == 0 then
		handles[handle] = nil
		mtask.ret()
	else
		assert(h.collect == nil, "Only one collect allows")
		h.collect = mtask.response()
	end
end

mtask.dispatch("lua", function(_,_,cmd,...)
	datasheet[cmd](...)
end)

mtask.info_func(function()
	local info = {}
	local tmp = {}
	for k,v in pairs(handles) do
		tmp[k] = v
	end
	for k,v in pairs(dataset) do
		local h = handles[v.handle]
		tmp[v.handle] = nil
		info[k] = {
			handle = v.handle,
			monitors = #v.monitor,
		}
	end
	for k,v in pairs(tmp) do
		info[k] = v.ref
	end

	return info
end)

end

mtask.init(function()
	address=service.new("datasheet", datasheet_service)
end)

return builder
