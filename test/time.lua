local mtask = require "mtask"
mtask.start(function()
    print(mtask.starttime())
    print(mtask.now())

    mtask.timeout(1, function()
        print("in 1", mtask.now())
    end)
    mtask.timeout(2, function()
        print("in 2", mtask.now())
    end)
    mtask.timeout(3, function()
        print("in 3", mtask.now())
    end)

    mtask.timeout(4, function()
        print("in 4", mtask.now())
    end)
    mtask.timeout(100, function()
        print("in 100", mtask.now())
    end)
end)
