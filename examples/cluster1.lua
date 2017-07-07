local mtask = require "mtask"
local cluster = require "mtask.cluster"
local snax = require "mtask.snax"

mtask.start(function()
	cluster.reload {
		db = "127.0.0.1:2528",
		db2 = "127.0.0.1:2529",
	}

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
