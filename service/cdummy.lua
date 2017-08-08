local mtask = require "mtask"
require "mtask.manager"	-- import mtask.launch, ...

local globalname = {}
local queryname = {}
local harbor = {}
local harbor_service

mtask.register_protocol {
	name = "harbor",
	id = mtask.PTYPE_HARBOR,
	pack = function(...) return ... end,
	unpack = mtask.tostring,
}

mtask.register_protocol {
	name = "text",
	id = mtask.PTYPE_TEXT,
	pack = function(...) return ... end,
	unpack = mtask.tostring,
}

local function response_name(name)
	local address = globalname[name]
	if queryname[name] then
		local tmp = queryname[name]
		queryname[name] = nil
		for _,resp in ipairs(tmp) do
			resp(true, address)
		end
	end
end

function harbor.REGISTER(name, handle)
	assert(globalname[name] == nil)
	globalname[name] = handle
	response_name(name)
	--发送到harbor.so服务
	mtask.redirect(harbor_service, handle, "harbor", 0, "N " .. name)
end

function harbor.QUERYNAME(name)
	if name:byte() == 46 then	-- "." , local name
		mtask.ret(mtask.pack(mtask.localname(name)))
		return
	end
	local result = globalname[name]
	if result then
		mtask.ret(mtask.pack(result))
		return
	end
	local queue = queryname[name]
	if queue == nil then
		queue = { mtask.response() }
		queryname[name] = queue
	else
		table.insert(queue, mtask.response())
	end
end

function harbor.LINK(id)
	mtask.ret()
end

function harbor.CONNECT(id)
	mtask.error("Can't connect to other harbor in single node mode")
end
mtask.start(function()
	local harbor_id = tonumber(mtask.getenv "harbor")
	assert(harbor_id == 0)

	mtask.dispatch("lua", function (session,source,command,...)
		local f = assert(harbor[command])
		f(...)
	end)
	mtask.dispatch("text", function(session,source,command)
		-- ignore all the command
	end)

	harbor_service = assert(mtask.launch("harbor", harbor_id, mtask.self()))
end)
