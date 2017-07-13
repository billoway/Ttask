-- You should use this module (mtask.coroutine) instead of origin lua coroutine in mtask framework
--[[
由于 mtask 框架的消息处理使用了 coroutine ，所以不可以将 lua 原本的 coroutine api 直接和 mtask 服务混用。
否则，mtask 的阻塞 API ,将调用 coroutine.yield 
而使得用户写的 coroutine.resume 有不可预期的返回值，并打乱 mtask 框架本身的处理流程
]]
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
	-- 如果resume的协程的状态是"BLOCKED"则将其父线程yield出来
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
	--如果你没有调用 mtask.coroutine.resume 启动一个 mtask coroutine 
	--而调用了 mtask.coroutine.yield 的话，会返回错误。
	--你可以在不同的 mtask 线程（由 mtask.fork 创建，或由一条新的外部消息创
	--建出的处理流程）中 resume 同一个 mtask coroutine 。
	--但如果该 coroutine 是由 mtask 框架（通常是调用了 mtask 的阻塞 API）
	--而不是 mtask.coroutine.yield 挂起的话，会被视为 normal 状态，resume 出错。
	--注：对于挂起在 mtask 框架下的 coroutine ，mtask.coroutine.status 会返回 "blocked" 。
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
	--它返回两个值，第一个是该 co 是由哪个 mtaks thread 间接调用的
	--如果 co 就是一个 mtask thread ，那么这个值和 coroutine.running() 一致，且第二个返回值为 true ，否则第二个返回值为 false 
	--第二个返回值可以用于判断一个 co 是否是由 mtask.coroutine.create 或 mtask.coroutine.wrap 创建出来的 coroutine 。
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
