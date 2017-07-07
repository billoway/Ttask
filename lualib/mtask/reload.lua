local core = require "mtask.reload.core"
local mtask = require "mtask"

local function reload(...)
	local args = SERVICE_NAME .. " " .. table.concat({...}, " ")
	print(args)
end

return reload
