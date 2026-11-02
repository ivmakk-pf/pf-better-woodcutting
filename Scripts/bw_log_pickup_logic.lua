-- Decisions of the log pickup, with plain numbers and tables. Game-free: no UE4SS global.
-- A position is a table with X, Y, Z in Unreal units (cm). A range is in metres.
local M = {}

---@class Pos
---@field X number
---@field Y number
---@field Z number

---@class LogEntry
---@field pos Pos where the log lies
---@field collected? boolean
---@field pending? boolean hidden by the mod, its pickup not resolved yet

local CM_PER_M = 100

---@param a Pos
---@param b Pos
---@return number
local function distSq(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return dx * dx + dy * dy + dz * dz
end

-- True when the cutter is within rangeM of the stump.
---@param cutterPos Pos
---@param stumpPos Pos
---@param rangeM number
---@return boolean
function M.inRange(cutterPos, stumpPos, rangeM)
    local range = rangeM * CM_PER_M
    return distSq(cutterPos, stumpPos) <= range * range
end

-- The first pass of the nearby scan: the logs ({ key, pos, ... }) within rangeM of pickedPos, not
-- the picked log itself. It needs only the position, so the other reads run only for these logs.
---@generic T: { key: any, pos: Pos }
---@param pickedPos Pos
---@param pickedKey any
---@param logs T[]
---@param rangeM number
---@return T[]
function M.logsInRange(pickedPos, pickedKey, logs, rangeM)
    local out = {}
    if rangeM <= 0 then return out end
    local range = rangeM * CM_PER_M
    local limit = range * range
    for _, entry in ipairs(logs) do
        if entry.key ~= pickedKey and distSq(pickedPos, entry.pos) <= limit then out[#out + 1] = entry end
    end
    return out
end

-- The entries of logs ({ pos, collected, pending, ... }) within rangeM of pickedPos, nearest first.
-- Collected and pending logs are skipped. A range of 0 gives none.
---@generic T: LogEntry
---@param pickedPos Pos
---@param logs T[]
---@param rangeM number
---@return T[]
function M.nearbyLogs(pickedPos, logs, rangeM)
    local out = {}
    if rangeM <= 0 then return out end
    local range = rangeM * CM_PER_M
    local limit = range * range
    for _, entry in ipairs(logs) do
        if not entry.collected and not entry.pending then
            local d = distSq(pickedPos, entry.pos)
            if d <= limit then out[#out + 1] = { entry = entry, d = d } end
        end
    end
    table.sort(out, function(a, b)
        return a.d < b.d
    end)
    for i, item in ipairs(out) do
        out[i] = item.entry
    end
    return out
end

-- The logs of one break: the tree spawns each log with itself as the owner. A log with no owner
-- (one loaded from a save) or another owner is dropped.
---@generic T
---@param entries { log: T, ownerKey: integer? }[]
---@param treeKey integer?
---@return T[] kept, integer dropped
function M.logsOfTree(entries, treeKey)
    local kept = {}
    for _, e in ipairs(entries) do
        if treeKey ~= nil and e.ownerKey == treeKey then kept[#kept + 1] = e.log end
    end
    return kept, #entries - #kept
end

-- The result of one pickup call, from the log state after it.
---@param after { valid: boolean, collected?: boolean }
---@return "picked up"|"shown again"
function M.pickupResult(after)
    if not after.valid or after.collected then return "picked up" end
    return "shown again"
end

return M
