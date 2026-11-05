local config_file = require("bw.core.config_file")

local SCHEMA = {
    { key = "log_pickup", default = true, comment = "Pick up the logs of a felled tree." },
    { key = "pickup_range_m", default = 15, min = 1, max = 100, comment = "Range from the stump, in metres." },
}

describe("the mod schema", function()
    it("writes a switch for each feature and verbose, with their defaults", function()
        local schema = require("bw.core.schema")
        local cfg = assert(load(config_file.text(schema)))()
        assert.are.equal(true, cfg.log_pickup)
        assert.are.equal(15, cfg.pickup_range_m)
        assert.are.equal(5, cfg.nearby_range_m)
        assert.are.equal(true, cfg.hit_assist)
        assert.are.equal(true, cfg.stump_removal)
        assert.are.equal(2, cfg.stump_hold_s)
        assert.are.equal(false, cfg.verbose)
        assert.are.equal(nil, cfg.enabled)
        assert.are.equal(7, #schema)
    end)

    it("keeps the stump hold time from 0.5 to 10 seconds, at the nearest limit", function()
        local schema = require("bw.core.schema")
        local validate = require("bw.core.config_logic").validate
        local warn = function() end
        assert.are.equal(0.5, validate({ stump_hold_s = 0.1 }, schema, warn).stump_hold_s)
        assert.are.equal(10, validate({ stump_hold_s = 60 }, schema, warn).stump_hold_s)
        assert.are.equal(3.5, validate({ stump_hold_s = 3.5 }, schema, warn).stump_hold_s)
    end)

    it("says in the comment of the hold time that the game adds its own second", function()
        local text = config_file.text(require("bw.core.schema"))
        assert.is_truthy(text:find("%-%- [^\n]*about 1 s[^\n]*%(0%.5 to 10, default 2%)\n%s*stump_hold_s = 2,"))
    end)
end)

describe("config_file.text", function()
    it("writes each key with its default, as a Lua file that returns a table", function()
        local text = config_file.text(SCHEMA)
        local chunk = assert(load(text))
        local cfg = chunk()
        assert.are.equal(true, cfg.log_pickup)
        assert.are.equal(15, cfg.pickup_range_m)
    end)

    it("writes the comment of each key above it, with the range of a number", function()
        local text = config_file.text(SCHEMA)
        assert(text:find("%-%- Pick up the logs of a felled tree%.\n%s*log_pickup = true,"), text)
        assert(
            text:find("%-%- Range from the stump, in metres%. %(1 to 100, default 15%)\n%s*pickup_range_m = 15,"),
            text
        )
    end)
end)
