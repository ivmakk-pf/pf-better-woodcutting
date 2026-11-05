local fakes = require("fakes")

local function lines(env, pattern)
    local n = 0
    for _, line in ipairs(env.printed) do
        if line:find(pattern) then n = n + 1 end
    end
    return n
end

describe("context", function()
    local env, ctx

    before_each(function()
        env = fakes.install()
        ctx = require("bw.core.context").new("T")
    end)

    after_each(function()
        fakes.restore()
    end)

    it("logs with the mod tag and a line break", function()
        ctx.log("hello")
        assert.are.equal("[T] hello\n", env.printed[1])
    end)

    it("traces only with verbose on", function()
        ctx.trace("quiet")
        ctx.config = { verbose = true }
        ctx.trace("loud")
        assert.are.same({ "[T] loud\n" }, env.printed)
    end)

    it("warns once for each key", function()
        ctx.warnOnce("k", "first")
        ctx.warnOnce("k", "second")
        assert.are.same({ "[T] WARN first\n" }, env.printed)
    end)

    it("guards a callback: an error logs one warning for its key", function()
        local fn = ctx.guard("cb", function()
            error("boom")
        end)
        fn()
        fn()
        assert.are.equal(1, lines(env, "WARN cb: .*boom"))
    end)

    it("guards a callback and gives its value back, so a hook can replace a return value", function()
        assert.is_true(ctx.guard("cb", function()
            return true
        end)())
        assert.is_nil(ctx.guard("cb", function()
            error("boom")
        end)())
    end)

    it("is not valid for nil, a destroyed object, or an object whose IsValid throws", function()
        assert.is_false(ctx.valid(nil))
        assert.is_false(ctx.valid(fakes.object({ destroyed = true })))
        assert.is_false(ctx.valid({
            IsValid = function()
                error("stale")
            end,
        }))
        assert.is_true(ctx.valid(fakes.object()))
    end)

    describe("hook", function()
        it("registers the callback in a guard and keeps the ids", function()
            assert.is_true(ctx.hook("k", "/Script/X.Y:Z", function()
                error("boom")
            end))
            assert.are.same({ 1, 2 }, ctx.hooks["/Script/X.Y:Z"])
            env.hooks["/Script/X.Y:Z"]()
            assert.are.equal(1, lines(env, "WARN k: .*boom"))
        end)

        it("logs one warning when the registration fails", function()
            env.failHook = ":Z"
            assert.is_false(ctx.hook("k", "/Script/X.Y:Z", function() end))
            assert.are.equal(1, lines(env, "WARN k hook failed %(a game change%?%)"))
        end)

        it("throws when a required registration fails", function()
            env.failHook = ":Z"
            assert.has_error(function()
                ctx.hook("k", "/Script/X.Y:Z", function() end, { required = true })
            end)
        end)
    end)

    -- A class lookup that misses walks the whole object array: the features read their
    -- paths from bw.paths and arm only from a watcher of the class.
    it("has no class lookup", function()
        local any = ctx ---@type any
        assert.is_nil(any.classPath)
    end)
end)
