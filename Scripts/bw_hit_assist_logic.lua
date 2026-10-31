-- Decisions of the hit assist, with plain values. Game-free: no UE4SS global.
-- A position or direction is a table with X, Y, Z in Unreal units (cm). Times are in seconds.
local M = {}

-- The game's own hit lands 0.59 to 0.65 s after SurfaceTrace, also the late hit of a short swing (whose
-- montage plays on after the ability ends): a swing is checked this long after its start.
M.GRACE_S = 0.8
-- The hold-to-chop loop hits a tree every 1.14 to 1.16 s: an assist never comes sooner than this after
-- the tree's last damage, so fast short clicks cannot chop faster than holding the button.
M.MIN_HIT_INTERVAL_S = 1.1
-- Against the trunk the prompt goes off and SurfaceTrace finds nothing: the last prompt tree is the
-- target when its prompt ended at most this long ago and it is within the prompt range.
M.RECENT_PROMPT_S = 5
M.NEAR_CM = 150

---@class Swing
---@field n integer the swing number
---@field target any the tree of the swing, nil when it is no tree
---@field startedAt number
---@field hit boolean
---@field ended boolean
---@field assisted boolean

---@class SwingState
---@field open Swing?
---@field count integer

-- True for a tree class: the numbered children (BP_ScavengableTree_102_C) and the parent class.
---@param className string?
---@return boolean
function M.isTree(className)
    if type(className) ~= "string" then return false end
    return className == "BP_ScavengeableTree_C" or className:match("^BP_ScavengableTree_.+_C$") ~= nil
end

-- True when the horizontal angle between forward and the direction to target is at most maxAngleDeg.
-- A target at the player's place counts as faced.
---@param playerPos Pos
---@param playerForward Pos
---@param targetPos Pos
---@param maxAngleDeg number
---@return boolean
function M.facing(playerPos, playerForward, targetPos, maxAngleDeg)
    local dx, dy = targetPos.X - playerPos.X, targetPos.Y - playerPos.Y
    local fx, fy = playerForward.X, playerForward.Y
    local lenD, lenF = math.sqrt(dx * dx + dy * dy), math.sqrt(fx * fx + fy * fy)
    if lenD < 1e-6 or lenF < 1e-9 then return true end
    local cos = (dx * fx + dy * fy) / (lenD * lenF)
    return cos >= math.cos(math.rad(maxAngleDeg)) - 1e-9
end

-- True when the held tool's type is the one that the tree asks for (an axe).
---@param toolType integer?
---@param requiredType integer?
---@return boolean
function M.rightTool(toolType, requiredType)
    return toolType ~= nil and toolType == requiredType
end

-- True when the last prompt (ended at endedAt) can still name the target: recent, near, and faced.
---@param endedAt number?
---@param now number
---@param distanceCm number
---@param faced boolean
---@return boolean
function M.recentPrompt(endedAt, now, distanceCm, faced)
    return endedAt ~= nil and now - endedAt <= M.RECENT_PROMPT_S and distanceCm <= M.NEAR_CM and faced
end

-- The swing's tree: the prompt tree, else the SurfaceTrace actor when it is a tree that the player faces,
-- else, only when the trace found no actor at all, the recent prompt tree (passed only when recentPrompt is true for it).
---@param promptTree any
---@param traceActor any
---@param traceClassName string?
---@param traceFaced boolean
---@param recentTree any
---@return any
function M.chooseTarget(promptTree, traceActor, traceClassName, traceFaced, recentTree)
    if promptTree ~= nil then return promptTree end
    -- Any other actor in the trace (a rock, an animal) is the swing's real target: no tree then.
    if traceActor ~= nil then
        if traceFaced and M.isTree(traceClassName) then return traceActor end
        return nil
    end
    return recentTree
end

---@return SwingState
function M.newState()
    return { open = nil, count = 0 }
end

-- Ends the open swing: returns it the first time, nil when no swing is open.
---@param state SwingState
---@return Swing?
function M.endSwing(state)
    local swing = state.open
    if not swing then return nil end
    state.open = nil
    swing.ended = true
    return swing
end

-- Starts a swing (at each SurfaceTrace); returns the swing that it ended, if one was open.
---@param state SwingState
---@param target any
---@param now number
---@return Swing?
function M.startSwing(state, target, now)
    local ended = M.endSwing(state)
    state.count = state.count + 1
    state.open = { n = state.count, target = target, startedAt = now, hit = false, ended = false, assisted = false }
    return ended
end

-- Records a hit of the game on the open swing's tree.
---@param state SwingState
function M.onHit(state)
    if state.open then state.open.hit = true end
end

-- True for a tree swing with no hit and no assist yet, when its tree took no damage since the swing start.
-- The swing may still be open. False once any newer swing started, at any target and also after it ended:
-- the assist uses the weapon state (ResetSwing, DurabilityDecreased) that the newer swing owns.
---@param swing Swing
---@param lastDamageAt number? when the swing's tree last took damage
---@param latestN integer? the number of the newest swing at the check (state.count)
---@param now number? the check time: no assist within MIN_HIT_INTERVAL_S after the tree's last damage
---@return boolean
function M.needsAssist(swing, lastDamageAt, latestN, now)
    if swing.target == nil or swing.hit or swing.assisted then return false end
    if latestN and latestN > swing.n then return false end
    if lastDamageAt == nil then return true end
    if now and now - lastDamageAt < M.MIN_HIT_INTERVAL_S then return false end
    return lastDamageAt < swing.startedAt
end

---@param swing Swing
function M.markAssisted(swing)
    swing.assisted = true
end

-- Restart of an interrupted hold ----------------------------------------------------
-- When the game interrupts a swing while the attack button is held, the game ends the attack and
-- starts a new one only at a new press. The mod restarts it, at most MAX_RESTARTS times in a row.

M.MAX_RESTARTS = 2

---@class HoldState
---@field held boolean the attack button is down
---@field restarts integer restarts since the last real key-down or hit on the tree

---@return HoldState
function M.newHold()
    return { held = false, restarts = 0 }
end

-- A key-down of the attack; own is true for the mod's own restart call, which keeps the count.
---@param hold HoldState
---@param own boolean
function M.onKeyDown(hold, own)
    hold.held = true
    if not own then hold.restarts = 0 end
end

---@param hold HoldState
function M.onKeyUp(hold)
    hold.held = false
end

---@param hold HoldState
function M.onRestart(hold)
    hold.restarts = hold.restarts + 1
end

---@param hold HoldState
function M.onTreeHit(hold)
    hold.restarts = 0
end

-- True for an interrupted tree swing while the button is held, below the restart limit.
---@param hold HoldState
---@param swing Swing?
---@return boolean
function M.shouldRestart(hold, swing)
    return hold.held and swing ~= nil and swing.target ~= nil and hold.restarts < M.MAX_RESTARTS
end

-- When to check a swing for an assist.
---@param swing Swing
---@return number
function M.assistAt(swing)
    return swing.startedAt + M.GRACE_S
end

return M
