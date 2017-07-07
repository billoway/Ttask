local mtask = require "mtask"
local harbor = require "mtask.harbor"
require "mtask.manager"	-- import mtask.launch, ...
local memory = require "mtask.memory"

mtask.start(function()
	local sharestring = tonumber(mtask.getenv "sharestring" or 4096)
	memory.ssexpand(sharestring)

	local standalone = mtask.getenv "standalone"

	local launcher = assert(mtask.launch("snlua","launcher"))
	mtask.name(".launcher", launcher)

	local harbor_id = tonumber(mtask.getenv "harbor" or 0)
	if harbor_id == 0 then
		assert(standalone ==  nil)
		standalone = true
		mtask.setenv("standalone", "true")

		local ok, slave = pcall(mtask.newservice, "cdummy")
		if not ok then
			mtask.abort()
		end
		mtask.name(".cslave", slave)

	else
		if standalone then
			if not pcall(mtask.newservice,"cmaster") then
				mtask.abort()
			end
		end

		local ok, slave = pcall(mtask.newservice, "cslave")
		if not ok then
			mtask.abort()
		end
		mtask.name(".cslave", slave)
	end

	if standalone then
		local datacenter = mtask.newservice "datacenterd"
		mtask.name("DATACENTER", datacenter)
	end
	mtask.newservice "service_mgr"
	pcall(mtask.newservice,mtask.getenv "start" or "main")
	mtask.exit()
end)
