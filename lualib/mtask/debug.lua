local io = io
local table = table
local debug = debug

return function (mtask, export)

local internal_info_func

function mtask.info_func(func)
	internal_info_func = func
end

local dbgcmd

local function init_dbgcmd()
dbgcmd = {}

function dbgcmd.MEM()
	local kb, bytes = collectgarbage "count"
	mtask.ret(mtask.pack(kb,bytes))
end

function dbgcmd.GC()
	export.clear()
	collectgarbage "collect"
end

function dbgcmd.STAT()
	local stat = {}
	stat.mqlen = mtask.mqlen()
	stat.task = mtask.task()
	mtask.ret(mtask.pack(stat))
end

function dbgcmd.TASK()
	local task = {}
	mtask.task(task)
	mtask.ret(mtask.pack(task))
end

function dbgcmd.INFO()
	if internal_info_func then
		mtask.ret(mtask.pack(internal_info_func()))
	else
		mtask.ret(mtask.pack(nil))
	end
end

function dbgcmd.EXIT()
	mtask.exit()
end

function dbgcmd.RUN(source, filename)
	local inject = require "mtask.inject"
	local output = inject(mtask, source, filename , export.dispatch, mtask.register_protocol)
	collectgarbage "collect"
	mtask.ret(mtask.pack(table.concat(output, "\n")))
end

function dbgcmd.TERM(service)
	mtask.term(service)
end

function dbgcmd.REMOTEDEBUG(...)
	local remotedebug = require "mtask.remotedebug"
	remotedebug.start(export, ...)
end

function dbgcmd.SUPPORT(pname)
	return mtask.ret(mtask.pack(mtask.dispatch(pname) ~= nil))
end

return dbgcmd
end -- function init_dbgcmd

local function _debug_dispatch(session, address, cmd, ...)
	local f = (dbgcmd or init_dbgcmd())[cmd]	-- lazy init dbgcmd
	assert(f, cmd)
	f(...)
end

mtask.register_protocol {
	name = "debug",
	id = assert(mtask.PTYPE_DEBUG),
	pack = assert(mtask.pack),
	unpack = assert(mtask.unpack),
	dispatch = _debug_dispatch,
}

end
