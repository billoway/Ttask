local mtask = require "mtask"
local express = {}
local _M = {}

--url_path,rule_path
function _M:use(...)
   mtask.send(self.web,"lua","use",...)
end

function _M:listen()
   mtask.call(self.web,"lua","start",self.port,self.config)
end
--web_root,static="*.html|*.css"
function express.app(port,config)
   local t = {port=port,config=config}
   local web = mtask.newservice("webd","master")
   t.web = web
   return setmetatable(t,{__index=_M})
end

return express