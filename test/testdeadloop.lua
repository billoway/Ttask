local mtask = require "mtask"
local function dead_loop()
    while true do
        mtask.sleep(0)
    end
end

mtask.start(function()
    mtask.fork(dead_loop)
end)
