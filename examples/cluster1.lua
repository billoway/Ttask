local mtask = require "mtask"
local cluster = require "cluster"
local snax = require "snax"

mtask.start(function()
	local sdb = mtask.newservice("simpledb")
	-- register name "sdb" for simpledb, you can use cluster.query() later.
	-- See cluster2.lua
	cluster.register("sdb", sdb)

	print(mtask.call(sdb, "lua", "SET", "a", "foobar"))
	print(mtask.call(sdb, "lua", "SET", "b", "foobar2"))
	print(mtask.call(sdb, "lua", "GET", "a"))
	print(mtask.call(sdb, "lua", "GET", "b"))
	cluster.open "db"
	cluster.open "db2"
	-- unique snax service
	snax.uniqueservice "pingserver"
end)
