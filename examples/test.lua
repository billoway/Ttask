local mtask = require "mtask"

local CMD = {}

function CMD.start()
    --mtask.error("CMD.start")
end

mtask.start(function()
    mtask.error("start")
    mtask.dispatch("lua", function (session,source,cmd,...)
       --print("session=>"..session)
       mtask.error("TTc dispatch",session,source,cmd)
       local f = CMD[cmd]
       assert(f, "service test can't dispatch cmd ".. (cmd or nil))
       
       if session > 0 then
           mtask.ret(mtask.pack(f(...)))
       else
           f(...)
       end
    end)
            
    
end)
