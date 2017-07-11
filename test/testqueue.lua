local mtask = require "mtask"
local snax = require "mtask.snax"

mtask.start(function()
	local ps = snax.uniqueservice ("pingserver", "test queue")
	for i=1, 10 do
		ps.post.sleep(true,i*10)
		ps.post.hello()
	end
	for i=1, 10 do
		ps.post.sleep(false,i*10)
		ps.post.hello()
	end

	mtask.exit()
end)


