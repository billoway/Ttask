local table = table
local extern_dbgcmd = {}

local function init(mtask, export)
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

			collectgarbage "collect"
		end

		function dbgcmd.STAT()
			local stat = {}
			stat.task = mtask.task()
			stat.mqlen = mtask.stat "mqlen"
			stat.cpu = mtask.stat "cpu"
			stat.message = mtask.stat "message"
			mtask.ret(mtask.pack(stat))
		end

		function dbgcmd.TASK()
			local task = {}
			mtask.task(task)
			mtask.ret(mtask.pack(task))
		end

		function dbgcmd.INFO(...)
			if internal_info_func then
				mtask.ret(mtask.pack(internal_info_func(...)))
			else
				mtask.ret(mtask.pack(nil))
			end
		end

		function dbgcmd.EXIT()
			mtask.exit()
		end

		function dbgcmd.RUN(source, filename)
			local inject = require "mtask.inject"
			local ok, output = inject(mtask, source, filename , export.dispatch, mtask.register_protocol)
			collectgarbage "collect"
			mtask.ret(mtask.pack(ok, table.concat(output, "\n")))
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

		function dbgcmd.PING()
			return mtask.ret()
		end

		function dbgcmd.LINK()
			mtask.response()	-- get response , but not return. raise error when exit
		end

		return dbgcmd
	end -- function init_dbgcmd

	local function _debug_dispatch(session, address, cmd, ...)
		dbgcmd = dbgcmd or init_dbgcmd() -- lazy init dbgcmd
		local f = dbgcmd[cmd] or extern_dbgcmd[cmd]
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

local function reg_debugcmd(name, fn)
	extern_dbgcmd[name] = fn
end

return {
	init = init,
	reg_debugcmd = reg_debugcmd,
}
