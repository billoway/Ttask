-- module proto as examples/proto.lua
package.path = "./examples/?.lua;" .. package.path

local mtask = require "mtask"
local sprotoparser = require "sprotoparser"
local sprotoloader = require "sprotoloader"
local proto = require "proto"

mtask.start(function()
	sprotoloader.save(proto.c2s, 1)
	sprotoloader.save(proto.s2c, 2)
	-- don't call mtask.exit() , because sproto.core may unload and the global slot become invalid
end)
