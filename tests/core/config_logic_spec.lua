local config_logic = require("bw.core.config_logic")

local SCHEMA = {
    { key = "log_pickup", default = true, comment = "switch" },
    { key = "pickup_range_m", default = 15, min = 1, max = 100, comment = "range" },
    { key = "verbose", default = false, comment = "log" },
}

local function collect()
    local warnings = {}
    return warnings, function(key, message)
        warnings[#warnings + 1] = key .. ": " .. message
    end
end

describe("config_logic.validate", function()
    it("gives the default for a missing key, with no warning", function()
        local warnings, warn = collect()
        local cfg = config_logic.validate({}, SCHEMA, warn)
        assert.are.equal(true, cfg.log_pickup)
        assert.are.equal(15, cfg.pickup_range_m)
        assert.are.equal(false, cfg.verbose)
        assert.are.equal(0, #warnings)
    end)

    it("keeps a valid value", function()
        local warnings, warn = collect()
        local cfg = config_logic.validate({ log_pickup = false, pickup_range_m = 30 }, SCHEMA, warn)
        assert.are.equal(false, cfg.log_pickup)
        assert.are.equal(30, cfg.pickup_range_m)
        assert.are.equal(0, #warnings)
    end)

    it("gives the default for a wrong type, with one warning", function()
        local warnings, warn = collect()
        local cfg = config_logic.validate({ log_pickup = "yes", pickup_range_m = 20 }, SCHEMA, warn)
        assert.are.equal(true, cfg.log_pickup)
        assert.are.equal(20, cfg.pickup_range_m)
        assert.are.equal(1, #warnings)
        assert.are.equal("log_pickup:", warnings[1]:sub(1, 11))
    end)

    it("takes the upper limit for a number above the range, with one warning", function()
        local warnings, warn = collect()
        local cfg = config_logic.validate({ pickup_range_m = 500 }, SCHEMA, warn)
        assert.are.equal(100, cfg.pickup_range_m)
        assert.are.equal(1, #warnings)
    end)

    it("takes the lower limit for a number below the range, with one warning", function()
        local warnings, warn = collect()
        local cfg = config_logic.validate({ pickup_range_m = 0 }, SCHEMA, warn)
        assert.are.equal(1, cfg.pickup_range_m)
        assert.are.equal(1, #warnings)
    end)

    it("keeps a number at the range edge, with no warning", function()
        local warnings, warn = collect()
        local cfg = config_logic.validate({ pickup_range_m = 100 }, SCHEMA, warn)
        assert.are.equal(100, cfg.pickup_range_m)
        assert.are.equal(0, #warnings)
    end)

    it("gives the default for NaN, with one warning", function()
        local warnings, warn = collect()
        local cfg = config_logic.validate({ pickup_range_m = 0 / 0 }, SCHEMA, warn)
        assert.are.equal(15, cfg.pickup_range_m)
        assert.are.equal(1, #warnings)
    end)

    it("ignores an unknown key", function()
        local warnings, warn = collect()
        local cfg = config_logic.validate({ old_setting = 3 }, SCHEMA, warn)
        assert.are.equal(nil, cfg.old_setting)
        assert.are.equal(0, #warnings)
    end)
end)
