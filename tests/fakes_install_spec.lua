-- The fakes themselves: a second install keeps the real globals, and two hooks on one path both run.
local fakes = require("fakes")

describe("fakes.install", function()
    it("restores the real globals also after a second install", function()
        local real = print
        fakes.install()
        fakes.install()
        fakes.restore()
        assert.are.equal(real, print)
    end)
end)

-- The UE4SS type of the callback has no return value; a Blueprint hook can return one.
local function hook(path, fn)
    local register = RegisterHook ---@type any
    register(path, fn)
end

describe("the fake RegisterHook", function()
    local env

    before_each(function()
        env = fakes.install()
    end)

    after_each(function()
        fakes.restore()
    end)

    it("runs each callback of a path in order, and gives the last value that is not nil", function()
        local calls = {}
        hook("/Game/X.Y_C:F", function()
            calls[#calls + 1] = "first"
            return true
        end)
        hook("/Game/X.Y_C:F", function()
            calls[#calls + 1] = "second"
        end)
        assert.is_true(env.hooks["/Game/X.Y_C:F"]())
        assert.are.same({ "first", "second" }, calls)
    end)
end)
