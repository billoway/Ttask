local mtask = require "mtask"

mtask.register_protocol {
	name = "client",
	id = mtask.PTYPE_CLIENT,
	unpack = mtask.tostring,
}

local gate
local userid, subid

local CMD = {}

function CMD.login(source, uid, sid, secret)
	-- you may use secret to make a encrypted data stream
	mtask.error(string.format("%s is login", uid))
	gate = source
	userid = uid
	subid = sid
	-- you may load user data from database
end

local function logout()
	if gate then
		mtask.call(gate, "lua", "logout", userid, subid)
	end
	mtask.exit()
end

function CMD.logout(source)
	-- NOTICE: The logout MAY be reentry
	mtask.error(string.format("%s is logout", userid))
	logout()
end

function CMD.afk(source)
	-- the connection is broken, but the user may back
	mtask.error(string.format("AFK"))
end

mtask.start(function()
	-- If you want to fork a work thread , you MUST do it in CMD.login
	mtask.dispatch("lua", function(session, source, command, ...)
		local f = assert(CMD[command])
		mtask.ret(mtask.pack(f(source, ...)))
	end)

	mtask.dispatch("client", function(_,_, msg)
		-- the simple echo service
		mtask.sleep(10)	-- sleep a while
		mtask.ret(msg)
	end)
end)
