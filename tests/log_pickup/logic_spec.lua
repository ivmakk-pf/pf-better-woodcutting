local logic = require("bw.log_pickup.logic")

local function at(x, y, z)
    return { X = x, Y = y or 0, Z = z or 0 }
end

describe("log_pickup_logic.inRange", function()
    it("is true at exactly the range (15 m = 1500 cm)", function()
        assert.are.equal(true, logic.inRange(at(1500), at(0), 15))
    end)

    it("is false just past the range", function()
        assert.are.equal(false, logic.inRange(at(1501), at(0), 15))
    end)

    it("measures in three dimensions", function()
        -- 900 and 1200 cm make a 1500 cm diagonal.
        assert.are.equal(true, logic.inRange(at(900, 0, 1200), at(0), 15))
        assert.are.equal(false, logic.inRange(at(900, 0, 1201), at(0), 15))
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
        assert.are.equal("near,far,edge", names(logic.nearbyLogs(at(0), logs, 5)))
    end)

    it("skips collected and pending logs", function()
        local logs = {
            { name = "collected", pos = at(100), collected = true },
            { name = "pending", pos = at(200), pending = true },
            { name = "free", pos = at(300) },
        }
        assert.are.equal("free", names(logic.nearbyLogs(at(0), logs, 5)))
    end)

    it("returns nothing for an empty list", function()
        assert.are.equal(0, #logic.nearbyLogs(at(0), {}, 5))
    end)

    it("returns nothing for a range of 0, also for a log at the same place", function()
        assert.are.equal(0, #logic.nearbyLogs(at(0), { { name = "same", pos = at(0) } }, 0))
    end)

    it("does not return a pending log in range", function()
        assert.are.equal(0, #logic.nearbyLogs(at(0), { { name = "hidden", pos = at(10), pending = true } }, 5))
    end)
end)

describe("log_pickup_logic.pickupResult", function()
    it("is picked up when the log is gone after the call", function()
        assert.are.equal("picked up", logic.pickupResult({ valid = false }))
    end)

    it("is picked up when the log is collected after the call", function()
        assert.are.equal("picked up", logic.pickupResult({ valid = true, collected = true }))
    end)

    it("is shown again when the log is still there and not collected", function()
        assert.are.equal("shown again", logic.pickupResult({ valid = true, collected = false }))
    end)
end)

describe("log_pickup_logic.logsOfTree", function()
    it("keeps the logs whose owner is the tree, in their order", function()
        local entries = { { log = "a", ownerKey = 7 }, { log = "b", ownerKey = 9 }, { log = "c", ownerKey = 7 } }
        local kept, dropped = logic.logsOfTree(entries, 7)
        assert.are.equal(2, #kept)
        assert.are.equal("a", kept[1])
        assert.are.equal("c", kept[2])
        assert.are.equal(1, dropped)
    end)

    it("drops a log with no owner (a log loaded from a save)", function()
        local kept, dropped = logic.logsOfTree({ { log = "a" } }, 7)
        assert.are.equal(0, #kept)
        assert.are.equal(1, dropped)
    end)

    it("keeps nothing when the tree key is unknown", function()
        local kept, dropped = logic.logsOfTree({ { log = "a", ownerKey = 7 } }, nil)
        assert.are.equal(0, #kept)
        assert.are.equal(1, dropped)
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
        assert.are.equal(2, #kept)
        assert.are.equal(1, kept[1].key)
        assert.are.equal(3, kept[2].key)
    end)

    it("returns nothing for a range of 0", function()
        assert.are.equal(0, #logic.logsInRange(at(0), nil, { { key = 1, pos = at(0) } }, 0))
    end)
end)

describe("log_pickup_logic log list", function()
    it("returns the logs that pass the check, in no fixed order", function()
        local list = {}
        logic.addLog(list, 1, "a")
        logic.addLog(list, 2, "b")
        local live = logic.liveLogs(list, function()
            return true
        end)
        table.sort(live)
        assert.are.same({ "a", "b" }, live)
    end)

    it("drops an entry that fails the check from the list", function()
        local list = {}
        logic.addLog(list, 1, "gone")
        logic.addLog(list, 2, "here")
        local checked = {}
        local live = logic.liveLogs(list, function(key, log)
            checked[#checked + 1] = key
            return log ~= "gone"
        end)
        assert.are.same({ "here" }, live)
        assert.are.equal(2, #checked)
        checked = {}
        logic.liveLogs(list, function(key)
            checked[#checked + 1] = key
            return true
        end)
        assert.are.same({ 2 }, checked)
    end)

    it("replaces the entry of a used key with the new log", function()
        local list = {}
        logic.addLog(list, 1, "old")
        logic.addLog(list, 1, "new")
        assert.are.same(
            { "new" },
            logic.liveLogs(list, function()
                return true
            end)
        )
    end)
end)
