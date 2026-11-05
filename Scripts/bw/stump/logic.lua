-- Decisions of the stump removal, with plain numbers and tables. Game-free: no UE4SS global.
local M = {}

-- The Wood Loot Count default of BP_TrunkPart (game/blueprints/.../BP_TrunkPart.txt:5).
local LOG_WOOD = 3

-- The wood of one log of a tree with this actor scale, as the game's
-- "Get Scale-Adjusted Trunk Wood Loot Count": max(1, round(3 * the largest of X, Y, Z)).
---@param scale { X: number, Y: number, Z: number }
---@return integer
function M.logWood(scale)
    local largest = math.max(scale.X, scale.Y, scale.Z)
    return math.max(1, math.floor(LOG_WOOD * largest + 0.5))
end

-- A stump is a felled tree: the game clamps the health of a felled tree at exactly 0.
---@param health number?
---@return boolean
function M.isStump(health)
    return health == 0
end

-- A removed stump: the mod marks it with a health below 0, which no game path sets.
---@param health number?
---@return boolean
function M.isRemoved(health)
    return health ~= nil and health < 0
end

return M
