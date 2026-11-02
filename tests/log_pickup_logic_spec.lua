local logic = require("bw_log_pickup_logic")

local function at(x, y, z)
    return { X = x, Y = y or 0, Z = z or 0 }
end

describe("log_pickup_logic.inRange", function()
    it("is true at exactly the range (15 m = 1500 cm)", function()
        assert_eq(logic.inRange(at(1500), at(0), 15), true)
    end)

    it("is false just past the range", function()
        assert_eq(logic.inRange(at(1501), at(0), 15), false)
    end)

    it("measures in three dimensions", function()
        -- 900 and 1200 cm make a 1500 cm diagonal.
        assert_eq(logic.inRange(at(900, 0, 1200), at(0), 15), true)
        assert_eq(logic.inRange(at(900, 0, 1201), at(0), 15), false)
    end)
end)

describe("log_pickup_logic.nearbyLogs", function()
    local function names(list)
        local out = {}
        for i, entry in ipairs(list) do
            out[i] = entry.name
        end
        return table.concat(out, ",")
    end

    it("returns the logs within the range, nearest first", function()
        local logs = {
            { name = "far", pos = at(400) },
            { name = "out", pos = at(501) },
            { name = "near", pos = at(100) },
            { name = "edge", pos = at(0, 500) },
        }
        assert_eq(names(logic.nearbyLogs(at(0), logs, 5)), "near,far,edge")
    end)

    it("skips collected and pending logs", function()
        local logs = {
            { name = "collected", pos = at(100), collected = true },
            { name = "pending", pos = at(200), pending = true },
            { name = "free", pos = at(300) },
        }
        assert_eq(names(logic.nearbyLogs(at(0), logs, 5)), "free")
    end)

    it("returns nothing for an empty list", function()
        assert_eq(#logic.nearbyLogs(at(0), {}, 5), 0)
    end)

    it("returns nothing for a range of 0, also for a log at the same place", function()
        assert_eq(#logic.nearbyLogs(at(0), { { name = "same", pos = at(0) } }, 0), 0)
    end)

    it("does not return a pending log in range", function()
        assert_eq(#logic.nearbyLogs(at(0), { { name = "hidden", pos = at(10), pending = true } }, 5), 0)
    end)
end)

describe("log_pickup_logic.pickupResult", function()
    it("is picked up when the log is gone after the call", function()
        assert_eq(logic.pickupResult({ valid = false }), "picked up")
    end)

    it("is picked up when the log is collected after the call", function()
        assert_eq(logic.pickupResult({ valid = true, collected = true }), "picked up")
    end)

    it("is shown again when the log is still there and not collected", function()
        assert_eq(logic.pickupResult({ valid = true, collected = false }), "shown again")
    end)
end)

describe("log_pickup_logic.logsOfTree", function()
    it("keeps the logs whose owner is the tree, in their order", function()
        local entries = { { log = "a", ownerKey = 7 }, { log = "b", ownerKey = 9 }, { log = "c", ownerKey = 7 } }
        local kept, dropped = logic.logsOfTree(entries, 7)
        assert_eq(#kept, 2)
        assert_eq(kept[1], "a")
        assert_eq(kept[2], "c")
        assert_eq(dropped, 1)
    end)

    it("drops a log with no owner (a log loaded from a save)", function()
        local kept, dropped = logic.logsOfTree({ { log = "a" } }, 7)
        assert_eq(#kept, 0)
        assert_eq(dropped, 1)
    end)

    it("keeps nothing when the tree key is unknown", function()
        local kept, dropped = logic.logsOfTree({ { log = "a", ownerKey = 7 } }, nil)
        assert_eq(#kept, 0)
        assert_eq(dropped, 1)
    end)
end)

describe("log_pickup_logic.logsInRange", function()
    it("keeps the logs within the range and drops the picked log by its key", function()
        local logs = {
            { key = 1, pos = at(100) },
            { key = 2, pos = at(501) },
            { key = 3, pos = at(0, 500) },
            { key = 4, pos = at(200) },
        }
        local kept = logic.logsInRange(at(0), 4, logs, 5)
        assert_eq(#kept, 2)
        assert_eq(kept[1].key, 1)
        assert_eq(kept[2].key, 3)
    end)

    it("returns nothing for a range of 0", function()
        assert_eq(#logic.logsInRange(at(0), nil, { { key = 1, pos = at(0) } }, 0), 0)
    end)
end)
