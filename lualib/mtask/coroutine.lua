-- You should use this module (mtask.coroutine) instead of origin lua coroutine in mtask framework

local coroutine = coroutine
-- origin lua coroutine module
local coroutine_resume = coroutine.resume
local coroutine_yield = coroutine.yield
local coroutine_status = coroutine.status
local coroutine_running = coroutine.running

local select = select
local mtaskco = {}

mtaskco.isyieldable = coroutine.isyieldable
mtaskco.running = coroutine.running
mtaskco.status = coroutine.status

local mtask_coroutines = setmetatable({}, { __mode = "kv" })

function mtaskco.create(f)
	local co = coroutine.create(f)
	-- mark co as a mtask coroutine
	mtask_coroutines[co] = true
	return co
end

do -- begin mtaskco.resume

	local profile = require "mtask.profile"
	-- mtask use profile.resume_co/yield_co instead of coroutine.resume/yield

	local mtask_resume = profile.resume_co
	local mtask_yield = profile.yield_co

	local function unlock(co, ...)
		mtask_coroutines[co] = true
		return ...
	end

	local function mtask_yielding(co, from, ...)
		mtask_coroutines[co] = false
		return unlock(co, mtask_resume(co, from, mtask_yield(from, ...)))
	end

	local function resume(co, from, ok, ...)
		if not ok then
			return ok, ...
		elseif coroutine_status(co) == "dead" then
			-- the main function exit
			mtask_coroutines[co] = nil
			return true, ...
		elseif (...) == "USER" then
			return true, select(2, ...)
		else
			-- blocked in mtask framework, so raise the yielding message
			return resume(co, from, mtask_yielding(co, from, ...))
		end
	end

	-- record the root of coroutine caller (It should be a mtask thread)
	local coroutine_caller = setmetatable({} , { __mode = "kv" })

function mtaskco.resume(co, ...)
	local co_status = mtask_coroutines[co]
	if not co_status then
		if co_status == false then
			-- is running
			return false, "cannot resume a mtask coroutine suspend by mtask framework"
		end
		if coroutine_status(co) == "dead" then
			-- always return false, "cannot resume dead coroutine"
			return coroutine_resume(co, ...)
		else
			return false, "cannot resume none mtask coroutine"
		end
	end
	local from = coroutine_running()
	local caller = coroutine_caller[from] or from
	coroutine_caller[co] = caller
	return resume(co, caller, coroutine_resume(co, ...))
end

function mtaskco.thread(co)
	co = co or coroutine_running()
	if mtask_coroutines[co] ~= nil then
		return coroutine_caller[co] , false
	else
		return co, true
	end
end

end -- end of mtaskco.resume

function mtaskco.status(co)
	local status = coroutine.status(co)
	if status == "suspended" then
		if mtask_coroutines[co] == false then
			return "blocked"
		else
			return "suspended"
		end
	else
		return status
	end
end

function mtaskco.yield(...)
	return coroutine_yield("USER", ...)
end

do -- begin mtaskco.wrap

	local function wrap_co(ok, ...)
		if ok then
			return ...
		else
			error(...)
		end
	end

function mtaskco.wrap(f)
	local co = mtaskco.create(function(...)
		return f(...)
	end)
	return function(...)
		return wrap_co(mtaskco.resume(co, ...))
	end
end

end	-- end of mtaskco.wrap

return mtaskco
