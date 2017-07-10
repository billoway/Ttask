local mtask = require "mtask"
local harbor = require "mtask.harbor"
require "mtask.manager"	-- import mtask.launch, ...
local memory = require "mtask.memory"

--默认 bootscript 启动脚本 、由 snlua 沙盒服务启动
--这段脚本通常会根据 standalone 配置项判断你启动的是一个 master 节点还是 slave 节点。
--如果是 master 节点还会进一步的通过 harbor 是否配置为 0 来判断你是否启动的是一个单节点 mtask 网络。
--单节点模式下，是不需要通过内置的 harbor 机制做节点间通讯的。
--但为了兼容（因为你还是有可能注册全局名字），需要启动一个叫做 cdummy 的服务，它负责拦截对外广播的全局名字变更。
--如果是多节点模式，对于 master 节点，需要启动 cmaster 服务作节点调度用。
--此外，每个节点（包括 master 节点自己）都需要启动 cslave 服务，用于节点间的消息转发，以及同步全局名字。
--接下来在 master 节点上，还需要启动 DataCenter 服务。
--然后，启动用于 UniqueService 管理的 service_mgr。
--最后，它从 config 中读取 start 这个配置项，作为用户定义的服务启动入口脚本运行。成功后，把自己退出。
print("bootstrap.lua  ....")
mtask.start(function()
	print("bootstrap.lua  start calling")
	local sharestring = tonumber(mtask.getenv "sharestring" or 4096)
	memory.ssexpand(sharestring)

	local standalone = mtask.getenv "standalone"

	local launcher = assert(mtask.launch("snlua","launcher"))
	mtask.name(".launcher", launcher)
	print("bootstrap.lua mtask.launch snlua （Lua sanbox）")

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
