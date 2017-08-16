local mtask = require "mtask"
local snax = require "mtask.snax"

mtask.start(function()
    local ps = snax.newservice("pingserver", "hello world")
    print(ps.req.ping("1000"))
    print(ps.post.hello("2000"))
end)
