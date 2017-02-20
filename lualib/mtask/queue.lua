local mtask = require "mtask"
local coroutine = coroutine
local xpcall = xpcall
local traceback = debug.traceback
local table = table

function mtask.queue()
	local current_thread
	local ref = 0
	local thread_queue = {}
	return function(f, ...)
		local thread = coroutine.running()
		if current_thread and current_thread ~= thread then
			table.insert(thread_queue, thread)
			mtask.wait()
			assert(ref == 0)	-- current_thread == thread
		end
		current_thread = thread

		ref = ref + 1
		local ok, err = xpcall(f, traceback, ...)
		ref = ref - 1
		if ref == 0 then
			current_thread = table.remove(thread_queue,1)
			if current_thread then
				mtask.wakeup(current_thread)
			end
		end
		assert(ok,err)
	end
end

return mtask.queue
