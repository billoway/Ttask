local mtask = require "mtask"

mtask.start(function()
	for i = 1, 1000000000 do	-- very long loop
		if i%100000000 == 0 then
			print("Endless = ", mtask.stat "endless")
			print("Cost time = ", mtask.stat "time")
		end
	end
	mtask.exit()
end)
