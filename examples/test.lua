local mtask = require "mtask"

local CMD = {}

function CMD.start(...)
    mtask.error(string.format("CMD.start %0x",...))
--    local test = mtask.newservice("test2")
 --   mtask.call(test,"lua","start",{"t1","t2","t3"})
end

function CMD.func1(source)
  --  mtask.error(string.format("CMD.func1 %s",source))
   -- mtask.call(source,"lua","func1",{"S1","S2","S3"})
end

mtask.start(function()
    mtask.error("test start")
    mtask.dispatch("lua", function (session,source,cmd,...)
       mtask.error(string.format("test.lua dispatch %s %0x %s %s",session,source,cmd,...))
       local f = CMD[cmd]
       assert(f, "service test can't dispatch cmd ".. (cmd or nil))
       if session > 0 then
           mtask.ret(mtask.pack(f(source)))
       else
           f(...)
       end
    end)
end)
