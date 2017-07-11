local mtask = require "mtask"

local names = {
	"cluster",
	"mtask.db.dns",
	"mtask.db.mongo",
	"mtask.db.mysql",
	"mtask.db.redis",
	"sharedata",
	"mtask.socket",
	"sproto"
}

-- set sandbox memory limit to 1M, must set here (at start, out of mtask.start)
mtask.memlimit(1 * 1024 * 1024)

mtask.start(function()
    local a = {}
    local limit
    local ok, err = pcall(function()
        for i=1, 12355 do
            limit = i
            table.insert(a, {})
        end
    end)
    local libs = {}
    for k,v in ipairs(names) do
        local ok, m = pcall(require, v)
        if ok then
            libs[v] = m
        end
    end
    mtask.error(limit, err)
    mtask.exit()
end)
