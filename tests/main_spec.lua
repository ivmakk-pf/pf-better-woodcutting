local fakes = require("fakes")

local FEATURE_MODULES = { "bw.log_pickup.feature", "bw.hit_assist.feature", "bw.stump.feature" }

-- Loads Scripts/main.lua with this config and stub feature modules. installs maps a module name to
-- a function that its install calls. Returns the fake env and the modules in install order.
local function loadMain(config, installs)
    installs = installs or {}
    local env = fakes.install()
    local order = {}
    package.loaded["bw.core.config_file"] = {
        load = function()
            return config
        end,
    }
    for _, name in ipairs(FEATURE_MODULES) do
        package.loaded[name] = {
            install = function(ctx)
                order[#order + 1] = name
                assert.are.equal(config, ctx.config)
                if installs[name] then installs[name](ctx) end
            end,
        }
    end
    dofile("Scripts/main.lua")
    return env, order
end

local function lines(env, pattern)
    local found = {}
    for _, line in ipairs(env.printed) do
        if line:find(pattern) then found[#found + 1] = line end
    end
    return found
end

local DEFAULTS = {
    log_pickup = true,
    pickup_range_m = 15,
    nearby_range_m = 5,
    hit_assist = true,
    stump_removal = true,
    stump_hold_s = 2,
    verbose = false,
}

local function with(changes)
    local cfg = {}
    for k, v in pairs(DEFAULTS) do
        cfg[k] = v
    end
    for k, v in pairs(changes) do
        cfg[k] = v
    end
    return cfg
end

describe("main", function()
    after_each(function()
        fakes.restore()
        package.loaded["bw.core.config_file"] = nil
        for _, name in ipairs(FEATURE_MODULES) do
            package.loaded[name] = nil
        end
    end)

    it("installs each feature in order and prints the load line with the switches", function()
        local env, order = loadMain(DEFAULTS)
        assert.are.same(FEATURE_MODULES, order)
        assert.are.equal(
            1,
            #lines(
                env,
                "^%[BetterWoodcutting%] v%d+%.%d+%.%d+ loaded %(log_pickup on, hit_assist on, stump_removal on%)\n$"
            )
        )
    end)

    it("skips the stump removal with stump_removal off", function()
        local env, order = loadMain(with({ stump_removal = false }))
        assert.are.same({ "bw.log_pickup.feature", "bw.hit_assist.feature" }, order)
        assert.are.equal(1, #lines(env, "hit_assist on, stump_removal off%)"))
    end)

    it("skips the hit assist with hit_assist off, and the load line says so", function()
        local env, order = loadMain(with({ hit_assist = false }))
        assert.are.same({ "bw.log_pickup.feature", "bw.stump.feature" }, order)
        assert.are.equal(1, #lines(env, "loaded %(log_pickup on, hit_assist off, stump_removal on%)"))
    end)

    it("skips the log pickup with log_pickup off", function()
        local env, order = loadMain(with({ log_pickup = false }))
        assert.are.same({ "bw.hit_assist.feature", "bw.stump.feature" }, order)
        assert.are.equal(1, #lines(env, "log_pickup off, hit_assist on"))
    end)

    it("gives one warning for a feature whose install throws, and still installs the others", function()
        local env, order = loadMain(DEFAULTS, {
            ["bw.log_pickup.feature"] = function()
                error("no class")
            end,
        })
        assert.are.same(FEATURE_MODULES, order)
        assert.are.equal(1, #lines(env, "WARN bw%.log_pickup%.feature not installed: .*no class"))
        assert.are.equal(1, #lines(env, "log_pickup FAILED, hit_assist on"))
    end)
end)
