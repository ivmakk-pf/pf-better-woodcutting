local logic = require("bw.stump.logic")

local function scale(x, y, z)
    return { X = x, Y = y, Z = z }
end

describe("stump_logic.logWood", function()
    it("is the wood of one log: 3 times the largest scale, rounded", function()
        assert.are.equal(3, logic.logWood(scale(1, 1, 1)))
        assert.are.equal(5, logic.logWood(scale(1, 1.5, 1.2)))
        assert.are.equal(4, logic.logWood(scale(1.2, 1, 0.5)))
        assert.are.equal(6, logic.logWood(scale(0.5, 0.5, 2)))
    end)

    it("is at least 1", function()
        assert.are.equal(1, logic.logWood(scale(0.1, 0.1, 0.1)))
        assert.are.equal(1, logic.logWood(scale(0, 0, 0)))
    end)
end)

describe("stump_logic.isStump", function()
    it("is true only for a health of exactly 0", function()
        assert.is_true(logic.isStump(0))
        assert.is_false(logic.isStump(-1))
        assert.is_false(logic.isStump(0.5))
        assert.is_false(logic.isStump(100))
        assert.is_false(logic.isStump(nil))
    end)
end)

describe("stump_logic.isRemoved", function()
    it("is true below 0", function()
        assert.is_true(logic.isRemoved(-1))
        assert.is_true(logic.isRemoved(-0.5))
        assert.is_false(logic.isRemoved(0))
        assert.is_false(logic.isRemoved(10))
        assert.is_false(logic.isRemoved(nil))
    end)
end)
