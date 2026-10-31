local logic = require("bw_hit_assist_logic")

local function at(x, y, z)
    return { X = x, Y = y or 0, Z = z or 0 }
end

describe("hit_assist_logic.isTree", function()
    it("is true for the numbered tree classes and the parent class", function()
        assert_eq(logic.isTree("BP_ScavengableTree_102_C"), true)
        assert_eq(logic.isTree("BP_ScavengableTree_111_C"), true)
        assert_eq(logic.isTree("BP_ScavengeableTree_C"), true)
    end)

    it("is false for a rock, a log, and nil", function()
        assert_eq(logic.isTree("BP_ScavengeableRock_C"), false)
        assert_eq(logic.isTree("BP_TrunkPart_C"), false)
        assert_eq(logic.isTree(nil), false)
    end)
end)

describe("hit_assist_logic.facing", function()
    it("is true straight ahead and at exactly the limit", function()
        assert_eq(logic.facing(at(0), at(1), at(100), 45), true)
        assert_eq(logic.facing(at(0), at(1), at(100, 100), 45), true)
    end)

    it("is false just past the limit", function()
        assert_eq(logic.facing(at(0), at(1), at(100, 101), 45), false)
    end)

    it("ignores the height", function()
        assert_eq(logic.facing(at(0), at(1, 0, -0.5), at(100, 0, 300), 10), true)
    end)

    it("is true when the target is at the player's place", function()
        assert_eq(logic.facing(at(5), at(1), at(5), 45), true)
    end)
end)

describe("hit_assist_logic.rightTool", function()
    it("is true only for the tool type that the tree asks for", function()
        assert_eq(logic.rightTool(1, 1), true)
        assert_eq(logic.rightTool(2, 1), false)
        assert_eq(logic.rightTool(nil, 1), false)
    end)
end)

describe("hit_assist_logic.chooseTarget", function()
    it("takes the prompt tree first", function()
        assert_eq(logic.chooseTarget("prompt", "other", "BP_ScavengableTree_102_C", true), "prompt")
    end)

    it("takes the trace tree when no prompt shows and the player faces it", function()
        assert_eq(logic.chooseTarget(nil, "trace", "BP_ScavengableTree_102_C", true), "trace")
        assert_eq(logic.chooseTarget(nil, "trace", "BP_ScavengableTree_102_C", false), nil)
    end)

    it("gives no target for a rock", function()
        assert_eq(logic.chooseTarget(nil, "rock", "BP_ScavengeableRock_C", true), nil)
    end)

    it("falls back to the recent prompt tree when the trace finds no tree", function()
        assert_eq(logic.chooseTarget(nil, nil, nil, false, "recent"), "recent")
        assert_eq(logic.chooseTarget(nil, "rock", "BP_ScavengeableRock_C", true, "recent"), nil, "a rock wins")
        assert_eq(logic.chooseTarget(nil, "deer", "BP_Deer_C", true, "recent"), nil, "an animal wins")
        assert_eq(logic.chooseTarget(nil, "trace", "BP_ScavengableTree_102_C", true, "recent"), "trace")
    end)
end)

describe("hit_assist_logic.recentPrompt", function()
    it("is true for a prompt that ended recently, a near tree, and a faced tree", function()
        assert_eq(logic.recentPrompt(10, 10 + logic.RECENT_PROMPT_S, logic.NEAR_CM, true), true)
    end)

    it("is false for an old prompt, a far tree, an unfaced tree, or no prompt at all", function()
        assert_eq(logic.recentPrompt(10, 10.01 + logic.RECENT_PROMPT_S, 50, true), false)
        assert_eq(logic.recentPrompt(10, 11, logic.NEAR_CM + 1, true), false)
        assert_eq(logic.recentPrompt(10, 11, 50, false), false)
        assert_eq(logic.recentPrompt(nil, 11, 50, true), false)
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
        assert_eq(logic.shouldRestart(hold, treeSwing()), true)
    end)

    it("does not restart after the button is released", function()
        local hold = logic.newHold()
        logic.onKeyDown(hold, false)
        logic.onKeyUp(hold)
        assert_eq(logic.shouldRestart(hold, treeSwing()), false)
    end)

    it("does not restart a swing with no tree (a rock) or no swing", function()
        local hold = logic.newHold()
        logic.onKeyDown(hold, false)
        local state = logic.newState()
        logic.startSwing(state, nil, 0)
        assert_eq(logic.shouldRestart(hold, logic.endSwing(state)), false)
        assert_eq(logic.shouldRestart(hold, nil), false)
    end)

    it("restarts at most MAX_RESTARTS times in a row", function()
        local hold = logic.newHold()
        logic.onKeyDown(hold, false)
        for _ = 1, logic.MAX_RESTARTS do
            assert_eq(logic.shouldRestart(hold, treeSwing()), true)
            logic.onRestart(hold)
            logic.onKeyDown(hold, true) -- the mod's own key-down call
        end
        assert_eq(logic.shouldRestart(hold, treeSwing()), false)
    end)

    it("resets the count at a real key-down", function()
        local hold = logic.newHold()
        logic.onKeyDown(hold, false)
        logic.onRestart(hold)
        logic.onRestart(hold)
        logic.onKeyDown(hold, false)
        assert_eq(logic.shouldRestart(hold, treeSwing()), true)
    end)

    it("resets the count at a hit on the tree", function()
        local hold = logic.newHold()
        logic.onKeyDown(hold, false)
        logic.onRestart(hold)
        logic.onRestart(hold)
        logic.onTreeHit(hold)
        assert_eq(logic.shouldRestart(hold, treeSwing()), true)
    end)
end)

describe("hit_assist_logic swing state", function()
    it("starts a swing with a number and its target", function()
        local state = logic.newState()
        assert_eq(logic.startSwing(state, "tree", 10), nil, "no open swing to end")
        assert_eq(state.open.n, 1)
        assert_eq(state.open.target, "tree")
        assert_eq(state.open.startedAt, 10)
    end)

    it("ends each of three looped swings once, at the next start or the ability end", function()
        local state = logic.newState()
        logic.startSwing(state, "tree", 0)
        local first = logic.startSwing(state, "tree", 1) --[[@as Swing]]
        local second = logic.startSwing(state, "tree", 2) --[[@as Swing]]
        local third = logic.endSwing(state) --[[@as Swing]]
        assert_eq(first.n, 1)
        assert_eq(second.n, 2)
        assert_eq(third.n, 3)
        assert_eq(first.ended and second.ended and third.ended, true)
    end)

    it("does nothing at a second end of the same swing", function()
        local state = logic.newState()
        logic.startSwing(state, "tree", 0)
        assert_eq(logic.endSwing(state).n, 1)
        assert_eq(logic.endSwing(state), nil)
    end)

    it("marks the open swing as hit", function()
        local state = logic.newState()
        logic.startSwing(state, "tree", 0)
        logic.onHit(state)
        assert_eq(logic.endSwing(state).hit, true)
    end)

    it("ignores a hit when no swing is open", function()
        local state = logic.newState()
        logic.onHit(state)
        assert_eq(state.open, nil)
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
        assert_eq(logic.needsAssist(endedSwing("tree", 10), nil), true)
        assert_eq(logic.needsAssist(endedSwing("tree", 10), 9.5), true, "damage before the swing")
    end)

    it("is false for a swing with no target (a rock)", function()
        assert_eq(logic.needsAssist(endedSwing(nil, 10), nil), false)
    end)

    it("is false for a swing that the game hit", function()
        local state = logic.newState()
        logic.startSwing(state, "tree", 10)
        logic.onHit(state)
        assert_eq(logic.needsAssist(logic.endSwing(state) --[[@as Swing]], nil), false)
    end)

    it("is false when the tree took damage after the swing start (a late hit of the montage)", function()
        assert_eq(logic.needsAssist(endedSwing("tree", 10), 10.6), false)
    end)

    it("is false at a second call after an assist", function()
        local swing = endedSwing("tree", 10)
        assert_eq(logic.needsAssist(swing, nil), true)
        logic.markAssisted(swing)
        assert_eq(logic.needsAssist(swing, nil), false)
    end)

    it("is true for a swing that is still the newest at the check (open or ended)", function()
        local state = logic.newState()
        logic.startSwing(state, "tree", 10)
        assert_eq(logic.needsAssist(state.open, nil, state.count), true, "open")
        local swing = logic.endSwing(state) --[[@as Swing]]
        assert_eq(logic.needsAssist(swing, nil, state.count), true, "ended")
    end)

    it("is false when a newer swing at the same tree started (it gets its own check)", function()
        local state = logic.newState()
        logic.startSwing(state, "tree", 10)
        local old = logic.startSwing(state, "tree", 10.5) --[[@as Swing]]
        assert_eq(logic.needsAssist(old, nil, state.count), false)
    end)

    it("is false when a newer swing at another target started, also after it ended (shared weapon state)", function()
        local state = logic.newState()
        logic.startSwing(state, "tree", 10)
        local old = logic.startSwing(state, "rock", 10.5) --[[@as Swing]]
        assert_eq(logic.needsAssist(old, nil, state.count), false, "newer open")
        logic.endSwing(state)
        assert_eq(logic.needsAssist(old, nil, state.count), false, "newer ended")
    end)

    it("is false within the vanilla swing interval after the tree's last damage (fast clicks)", function()
        local swing = endedSwing("tree", 10)
        assert_eq(logic.needsAssist(swing, 9.9, nil, 10.8), false, "0.9 s gap")
        assert_eq(logic.needsAssist(swing, 9.7, nil, 9.71 + logic.MIN_HIT_INTERVAL_S), true, "just past the interval")
    end)

    it("waits past the latest game hit seen (0.65 s after the start)", function()
        assert_eq(logic.GRACE_S, 0.8)
    end)

    it("checks a swing a grace time after its start", function()
        assert_eq(logic.assistAt(endedSwing("tree", 10)), 10 + logic.GRACE_S)
    end)
end)
