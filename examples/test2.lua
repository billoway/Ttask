local mtask = require "mtask"

local CMD = {}

function CMD.start(source)
    mtask.error(string.format("CMD.start %0x",source))
    --mtask.call(source,"lua","func1",{"F1","F2","F3"})
end

function CMD.func1(...)
    mtask.error(string.format("CMD.func1 %s",...))
end

mtask.start(function()
    mtask.error("test2.lua start")
    mtask.dispatch("lua", function (session,source,cmd,...)
       mtask.error(string.format("test2.lua dispatch %s %0x %s %s",session,source,cmd,...))
       local f = CMD[cmd]
       assert(f, "service test can't dispatch cmd ".. (cmd or nil))
                   
       if session > 0 then
           mtask.ret(mtask.pack(f(source)))
       else
           f(...)
       end
    end)
end)
