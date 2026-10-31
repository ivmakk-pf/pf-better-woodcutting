local config_logic = require("bw_config_logic")

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
        assert_eq(cfg.log_pickup, true)
        assert_eq(cfg.pickup_range_m, 15)
        assert_eq(cfg.verbose, false)
        assert_eq(#warnings, 0)
    end)

    it("keeps a valid value", function()
        local warnings, warn = collect()
        local cfg = config_logic.validate({ log_pickup = false, pickup_range_m = 30 }, SCHEMA, warn)
        assert_eq(cfg.log_pickup, false)
        assert_eq(cfg.pickup_range_m, 30)
        assert_eq(#warnings, 0)
    end)

    it("gives the default for a wrong type, with one warning", function()
        local warnings, warn = collect()
        local cfg = config_logic.validate({ log_pickup = "yes", pickup_range_m = 20 }, SCHEMA, warn)
        assert_eq(cfg.log_pickup, true)
        assert_eq(cfg.pickup_range_m, 20)
        assert_eq(#warnings, 1)
        assert_eq(warnings[1]:sub(1, 11), "log_pickup:")
    end)

    it("takes the upper limit for a number above the range, with one warning", function()
        local warnings, warn = collect()
        local cfg = config_logic.validate({ pickup_range_m = 500 }, SCHEMA, warn)
        assert_eq(cfg.pickup_range_m, 100)
        assert_eq(#warnings, 1)
    end)

    it("takes the lower limit for a number below the range, with one warning", function()
        local warnings, warn = collect()
        local cfg = config_logic.validate({ pickup_range_m = 0 }, SCHEMA, warn)
        assert_eq(cfg.pickup_range_m, 1)
        assert_eq(#warnings, 1)
    end)

    it("keeps a number at the range edge, with no warning", function()
        local warnings, warn = collect()
        local cfg = config_logic.validate({ pickup_range_m = 100 }, SCHEMA, warn)
        assert_eq(cfg.pickup_range_m, 100)
        assert_eq(#warnings, 0)
    end)

    it("gives the default for NaN, with one warning", function()
        local warnings, warn = collect()
        local cfg = config_logic.validate({ pickup_range_m = 0 / 0 }, SCHEMA, warn)
        assert_eq(cfg.pickup_range_m, 15)
        assert_eq(#warnings, 1)
    end)

    it("ignores an unknown key", function()
        local warnings, warn = collect()
        local cfg = config_logic.validate({ old_setting = 3 }, SCHEMA, warn)
        assert_eq(cfg.old_setting, nil)
        assert_eq(#warnings, 0)
    end)
end)
