local config_file = require("bw_config_file")

local SCHEMA = {
    { key = "log_pickup", default = true, comment = "Pick up the logs of a felled tree." },
    { key = "pickup_range_m", default = 15, min = 1, max = 100, comment = "Range from the stump, in metres." },
}

describe("config_file.text", function()
    it("writes each key with its default, as a Lua file that returns a table", function()
        local text = config_file.text(SCHEMA)
        local chunk = assert(load(text))
        local cfg = chunk()
        assert_eq(cfg.log_pickup, true)
        assert_eq(cfg.pickup_range_m, 15)
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
