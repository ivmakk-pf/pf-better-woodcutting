local logic = require("bw.hit_assist.logic")

local function at(x, y, z)
    return { X = x, Y = y or 0, Z = z or 0 }
end

describe("hit_assist_logic.isTree", function()
    it("is true for the numbered tree classes and the parent class", function()
        assert.are.equal(true, logic.isTree("BP_ScavengableTree_102_C"))
        assert.are.equal(true, logic.isTree("BP_ScavengableTree_111_C"))
        assert.are.equal(true, logic.isTree("BP_ScavengeableTree_C"))
    end)

    it("is false for a rock, a log, and nil", function()
        assert.are.equal(false, logic.isTree("BP_ScavengeableRock_C"))
        assert.are.equal(false, logic.isTree("BP_TrunkPart_C"))
        assert.are.equal(false, logic.isTree(nil))
    end)
end)

describe("hit_assist_logic.facing", function()
    it("is true straight ahead and at exactly the limit", function()
        assert.are.equal(true, logic.facing(at(0), at(1), at(100), 45))
        assert.are.equal(true, logic.facing(at(0), at(1), at(100, 100), 45))
    end)

    it("is false just past the limit", function()
        assert.are.equal(false, logic.facing(at(0), at(1), at(100, 101), 45))
    end)

    it("ignores the height", function()
        assert.are.equal(true, logic.facing(at(0), at(1, 0, -0.5), at(100, 0, 300), 10))
    end)

    it("is true when the target is at the player's place", function()
        assert.are.equal(true, logic.facing(at(5), at(1), at(5), 45))
    end)
end)

describe("hit_assist_logic.rightTool", function()
    it("is true only for the tool type that the tree asks for", function()
        assert.are.equal(true, logic.rightTool(1, 1))
        assert.are.equal(false, logic.rightTool(2, 1))
        assert.are.equal(false, logic.rightTool(nil, 1))
    end)
end)

describe("hit_assist_logic.chooseTarget", function()
    it("takes the prompt tree first", function()
        assert.are.equal("prompt", logic.chooseTarget("prompt", "other", "BP_ScavengableTree_102_C", true))
    end)

    it("takes the trace tree when no prompt shows and the player faces it", function()
        assert.are.equal("trace", logic.chooseTarget(nil, "trace", "BP_ScavengableTree_102_C", true))
        assert.are.equal(nil, logic.chooseTarget(nil, "trace", "BP_ScavengableTree_102_C", false))
    end)

    it("gives no target for a rock", function()
        assert.are.equal(nil, logic.chooseTarget(nil, "rock", "BP_ScavengeableRock_C", true))
    end)

    it("falls back to the recent prompt tree when the trace finds no tree", function()
        assert.are.equal("recent", logic.chooseTarget(nil, nil, nil, false, "recent"))
        assert.are.equal(nil, logic.chooseTarget(nil, "rock", "BP_ScavengeableRock_C", true, "recent"), "a rock wins")
        assert.are.equal(nil, logic.chooseTarget(nil, "deer", "BP_Deer_C", true, "recent"), "an animal wins")
        assert.are.equal("trace", logic.chooseTarget(nil, "trace", "BP_ScavengableTree_102_C", true, "recent"))
    end)
end)

describe("hit_assist_logic.recentPrompt", function()
    it("is true for a prompt that ended recently, a near tree, and a faced tree", function()
        assert.are.equal(true, logic.recentPrompt(10, 10 + logic.RECENT_PROMPT_S, logic.NEAR_CM, true))
    end)

    it("is false for an old prompt, a far tree, an unfaced tree, or no prompt at all", function()
        assert.are.equal(false, logic.recentPrompt(10, 10.01 + logic.RECENT_PROMPT_S, 50, true))
        assert.are.equal(false, logic.recentPrompt(10, 11, logic.NEAR_CM + 1, true))
        assert.are.equal(false, logic.recentPrompt(10, 11, 50, false))
        assert.are.equal(false, logic.recentPrompt(nil, 11, 50, true))
    end)
end)

describe("hit_assist_logic restart of an interrupted hold", function()
    local function treeSwing()
        local state = logic.newState()
        logic.startSwing(state, "tree", 0)
        return logic.endSwing(state) --[[@as Swing]]
    end

    it("restarts a tree swing while the button is held", function()
        local hold = logic.newHold()
        logic.onKeyDown(hold, false)
        assert.are.equal(true, logic.shouldRestart(hold, treeSwing()))
    end)

    it("does not restart after the button is released", function()
        local hold = logic.newHold()
        logic.onKeyDown(hold, false)
        logic.onKeyUp(hold)
        assert.are.equal(false, logic.shouldRestart(hold, treeSwing()))
    end)

    it("does not restart a swing with no tree (a rock) or no swing", function()
        local hold = logic.newHold()
        logic.onKeyDown(hold, false)
        local state = logic.newState()
        logic.startSwing(state, nil, 0)
        assert.are.equal(false, logic.shouldRestart(hold, logic.endSwing(state)))
        assert.are.equal(false, logic.shouldRestart(hold, nil))
    end)

    it("restarts at most MAX_RESTARTS times in a row", function()
        local hold = logic.newHold()
        logic.onKeyDown(hold, false)
        for _ = 1, logic.MAX_RESTARTS do
            assert.are.equal(true, logic.shouldRestart(hold, treeSwing()))
            logic.onRestart(hold)
            logic.onKeyDown(hold, true) -- the mod's own key-down call
        end
        assert.are.equal(false, logic.shouldRestart(hold, treeSwing()))
    end)

    it("resets the count at a real key-down", function()
        local hold = logic.newHold()
        logic.onKeyDown(hold, false)
        logic.onRestart(hold)
        logic.onRestart(hold)
        logic.onKeyDown(hold, false)
        assert.are.equal(true, logic.shouldRestart(hold, treeSwing()))
    end)

    it("resets the count at a hit on the tree", function()
        local hold = logic.newHold()
        logic.onKeyDown(hold, false)
        logic.onRestart(hold)
        logic.onRestart(hold)
        logic.onTreeHit(hold)
        assert.are.equal(true, logic.shouldRestart(hold, treeSwing()))
    end)
end)

describe("hit_assist_logic swing state", function()
    it("starts a swing with a number and its target", function()
        local state = logic.newState()
        assert.are.equal(nil, logic.startSwing(state, "tree", 10), "no open swing to end")
        assert.are.equal(1, state.open.n)
        assert.are.equal("tree", state.open.target)
        assert.are.equal(10, state.open.startedAt)
    end)

    it("ends each of three looped swings once, at the next start or the ability end", function()
        local state = logic.newState()
        logic.startSwing(state, "tree", 0)
        local first = logic.startSwing(state, "tree", 1) --[[@as Swing]]
        local second = logic.startSwing(state, "tree", 2) --[[@as Swing]]
        local third = logic.endSwing(state) --[[@as Swing]]
        assert.are.equal(1, first.n)
        assert.are.equal(2, second.n)
        assert.are.equal(3, third.n)
        assert.are.equal(true, first.ended and second.ended and third.ended)
    end)

    it("does nothing at a second end of the same swing", function()
        local state = logic.newState()
        logic.startSwing(state, "tree", 0)
        assert.are.equal(1, logic.endSwing(state).n)
        assert.are.equal(nil, logic.endSwing(state))
    end)

    it("marks the open swing as hit", function()
        local state = logic.newState()
        logic.startSwing(state, "tree", 0)
        logic.onHit(state)
        assert.are.equal(true, logic.endSwing(state).hit)
    end)

    it("ignores a hit when no swing is open", function()
        local state = logic.newState()
        logic.onHit(state)
        assert.are.equal(nil, state.open)
    end)
end)

describe("hit_assist_logic.needsAssist", function()
    ---@return Swing
    local function endedSwing(target, startedAt)
        local state = logic.newState()
        logic.startSwing(state, target, startedAt)
        return logic.endSwing(state) --[[@as Swing]]
    end

    it("is true for a tree swing with no hit and no damage since its start", function()
        assert.are.equal(true, logic.needsAssist(endedSwing("tree", 10), nil))
        assert.are.equal(true, logic.needsAssist(endedSwing("tree", 10), 9.5), "damage before the swing")
    end)

    it("is false for a swing with no target (a rock)", function()
        assert.are.equal(false, logic.needsAssist(endedSwing(nil, 10), nil))
    end)

    it("is false for a swing that the game hit", function()
        local state = logic.newState()
        logic.startSwing(state, "tree", 10)
        logic.onHit(state)
        assert.are.equal(false, logic.needsAssist(logic.endSwing(state) --[[@as Swing]], nil))
    end)

    it("is false when the tree took damage after the swing start (a late hit of the montage)", function()
        assert.are.equal(false, logic.needsAssist(endedSwing("tree", 10), 10.6))
    end)

    it("is false at a second call after an assist", function()
        local swing = endedSwing("tree", 10)
        assert.are.equal(true, logic.needsAssist(swing, nil))
        logic.markAssisted(swing)
        assert.are.equal(false, logic.needsAssist(swing, nil))
    end)

    it("is true for a swing that is still the newest at the check (open or ended)", function()
        local state = logic.newState()
        logic.startSwing(state, "tree", 10)
        assert.are.equal(true, logic.needsAssist(state.open, nil, state.count), "open")
        local swing = logic.endSwing(state) --[[@as Swing]]
        assert.are.equal(true, logic.needsAssist(swing, nil, state.count), "ended")
    end)

    it("is false when a newer swing at the same tree started (it gets its own check)", function()
        local state = logic.newState()
        logic.startSwing(state, "tree", 10)
        local old = logic.startSwing(state, "tree", 10.5) --[[@as Swing]]
        assert.are.equal(false, logic.needsAssist(old, nil, state.count))
    end)

    it("is false when a newer swing at another target started, also after it ended (shared weapon state)", function()
        local state = logic.newState()
        logic.startSwing(state, "tree", 10)
        local old = logic.startSwing(state, "rock", 10.5) --[[@as Swing]]
        assert.are.equal(false, logic.needsAssist(old, nil, state.count), "newer open")
        logic.endSwing(state)
        assert.are.equal(false, logic.needsAssist(old, nil, state.count), "newer ended")
    end)

    it("is false within the vanilla swing interval after the tree's last damage (fast clicks)", function()
        local swing = endedSwing("tree", 10)
        assert.are.equal(false, logic.needsAssist(swing, 9.9, nil, 10.8), "0.9 s gap")
        assert.are.equal(
            true,
            logic.needsAssist(swing, 9.7, nil, 9.71 + logic.MIN_HIT_INTERVAL_S),
            "just past the interval"
        )
    end)

    it("waits past the latest game hit seen (0.65 s after the start)", function()
        assert.are.equal(0.8, logic.GRACE_S)
    end)

    it("checks a swing a grace time after its start", function()
        assert.are.equal(10 + logic.GRACE_S, logic.assistAt(endedSwing("tree", 10)))
    end)
end)

describe("hit_assist_logic.treeDown", function()
    it("is true for a tree that the game marked as scavenged (it falls and takes no damage)", function()
        assert.are.equal(true, logic.treeDown(true))
    end)

    it("is true when the read failed, so the swing stays vanilla", function()
        assert.are.equal(true, logic.treeDown(nil))
    end)

    it("is false for a standing tree", function()
        assert.are.equal(false, logic.treeDown(false, 100))
    end)

    it("is true for a stump after a load: the game does not save bScavenged, the health stays 0", function()
        assert.are.equal(true, logic.treeDown(false, 0))
    end)

    it("is true for a removed stump (a health below 0)", function()
        assert.are.equal(true, logic.treeDown(false, -1))
    end)

    it("is true when the health read failed", function()
        assert.are.equal(true, logic.treeDown(false, nil))
    end)
end)
