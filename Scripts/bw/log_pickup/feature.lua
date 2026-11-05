-- Log pickup: the logs of a felled tree go into the inventory of the player who cut it.
-- Runs on the host: every hook acts only where the tree has authority.
--
-- In this UE4SS build a Blueprint hook callback runs after the function body, and a
-- second (post) callback never runs. The code below relies on that order.
local logic = require("bw.log_pickup.logic")
local PATHS = require("bw.paths")

local M = {}

local TREE_CLASS = "BP_ScavengeableTree_C"
local LOG_CLASS = "BP_TrunkPart_C"
local PICKUP_DELAY_MS = 200 -- after Custom Mining & Woodcutting Yield changes the wood (one frame)
local RECENT_KEEP_S = 0.5

local ctx ---@type FeatureContext set by install

local state = {
    pending = {}, -- log name -> true while it is hidden and its pickup is not resolved
    recent = {}, -- { log, t } of logs made in the last RECENT_KEEP_S
    picking = false, -- true while the mod calls a pickup itself
    logs = {}, -- the log list: address -> each log that the game made in this session
    treeArmed = false,
}

---@param obj any
---@return string
local function nameOf(obj)
    return ctx.try(function()
        return obj:GetFName():ToString()
    end) or "?"
end

-- The address keys a game object across the different Lua wrappers; nil for an invalid object.
---@param obj any
---@return any
local function keyOf(obj)
    if not ctx.valid(obj) then return nil end
    return ctx.try(function()
        return obj:GetAddress()
    end)
end

-- nil when the read fails: check the result with valid() before use.
---@param lg ABP_TrunkPart_C
---@return UStaticMeshComponent
local function meshOf(lg)
    return ctx.try(function()
        return lg.ResourceMesh
    end)
end

-- The mesh simulates physics apart from the actor, so its location is where the log lies.
---@param lg ABP_TrunkPart_C
---@return any position with X, Y, Z, or nil
local function logPos(lg)
    local mesh = meshOf(lg)
    if ctx.valid(mesh) then
        return ctx.try(function()
            return mesh:K2_GetComponentLocation()
        end)
    end
    return ctx.try(function()
        return lg:K2_GetActorLocation()
    end)
end

-- Append only: a map load can make hundreds of saved logs in one burst. The recent list is
-- rebuilt only when its oldest entry is stale, so each log costs one insert and one table write.
local function onNewLog(obj)
    local now = os.clock()
    if state.recent[1] and now - state.recent[1].t > RECENT_KEEP_S then state.recent = {} end
    state.recent[#state.recent + 1] = { log = obj, t = now }
    -- Only the nearby walk reads the log list, and only that walk drops its destroyed logs.
    if ctx.config.nearby_range_m <= 0 then return end
    local key = keyOf(obj)
    if key then logic.addLog(state.logs, key, obj) end
end

-- An entry of the log list is used only while it is still that log: UE4SS IsValid checks only that
-- the address holds a live object, so a freed log whose address another object took passes it.
---@param key any
---@param lg any
---@return boolean
local function sameLog(key, lg)
    return ctx.valid(lg)
        and ctx.try(function()
            return lg:GetClass():GetFName():ToString()
        end) == LOG_CLASS
        and keyOf(lg) == key
end

-- Hide and freeze, and show again -----------------------------------------

-- Each step runs on its own, so one failed step never leaves the others undone.
local function step(key, fn)
    local ok, err = pcall(fn)
    if not ok then ctx.warnOnce(key, key .. ": " .. tostring(err)) end
    return ok
end

-- Restore order: transform, physics, collision, visibility. Every new log simulates
-- physics (probe), so physics always comes back on.
---@param lg ABP_TrunkPart_C
---@param saved { loc: any, rot: any }
local function show(lg, saved)
    local mesh = meshOf(lg)
    if ctx.valid(mesh) and saved.loc and saved.rot then
        step("show transform", function()
            mesh:K2_SetWorldLocationAndRotation(saved.loc, saved.rot, false, {}, true)
        end)
    end
    if ctx.valid(mesh) then step("show physics", function()
        mesh:SetSimulatePhysics(true)
    end) end
    step("show collision", function()
        lg:SetActorEnableCollision(true)
    end)
    step("show visibility", function()
        lg:SetActorHiddenInGame(false)
    end)
end

-- Returns the saved transform, or nil after a failed step (then the log is shown again).
---@param lg ABP_TrunkPart_C
---@return { loc: any, rot: any }?
local function hide(lg)
    local mesh = meshOf(lg)
    local saved = {
        loc = ctx.valid(mesh) and ctx.try(function()
            return mesh:K2_GetComponentLocation()
        end) or nil,
        rot = ctx.valid(mesh) and ctx.try(function()
            return mesh:K2_GetComponentRotation()
        end) or nil,
    }
    local ok = (not ctx.valid(mesh) or step("hide physics", function()
        mesh:SetSimulatePhysics(false)
    end)) and step("hide collision", function()
        lg:SetActorEnableCollision(false)
    end) and step("hide visibility", function()
        lg:SetActorHiddenInGame(true)
    end)
    if ok then return saved end
    show(lg, saved)
    return nil
end

-- The pickup ----------------------------------------------------------------

-- The game's own pickup path: BeginInteraction (BP_InteractionBase) stops at a lock and calls
-- StartInteraction; the log's AUTHORITY_HandleStartInteraction sets bCollected and adds the wood.
---@param lg ABP_TrunkPart_C
---@param character AActor
---@return "picked up"|"shown again"
local function pickup(lg, character)
    -- The character can be gone by the delayed pickup (a client left): never pass a stale object.
    if not ctx.valid(character) then
        ctx.warnOnce("pickup character", "the player is gone; the log stays on the ground")
        return "shown again"
    end
    state.picking = true
    local ok, err = pcall(function()
        lg:BeginInteraction({ ID = FName("Interact") }, character)
    end)
    state.picking = false
    if not ok then ctx.warnOnce("pickup call", "pickup call failed: " .. tostring(err)) end
    return logic.pickupResult({
        valid = ctx.valid(lg),
        collected = ctx.try(function()
            return lg.bCollected
        end) == true,
    })
end

local function pickupBreak(logs, character)
    for _, item in ipairs(logs) do
        local lg, name = item.log, item.name
        if ctx.valid(lg) then
            local wood = ctx.try(function()
                return lg["Wood Loot Count"]
            end)
            local result = pickup(lg, character)
            if result ~= "picked up" then
                show(lg, item.saved)
                ctx.warnOnce("not picked", "a log was not picked up (a game change?); it stays on the ground")
            end
            ctx.trace(string.format("log %s wood=%s %s", name, tostring(wood), result))
        end
        state.pending[name] = nil
    end
end

-- The cutter: Damage Cause is the character; its owner is a fallback.
---@param tree ABP_ScavengeableTree_C
---@return ABP_SGKMasterCharacter_C?
local function cutterOf(tree)
    local cause = ctx.try(function()
        return tree["Damage Cause"]
    end)
    for _, candidate in ipairs({
        cause,
        ctx.valid(cause) and ctx.try(function()
            return cause:GetOwner()
        end) or nil,
    }) do
        if
            ctx.valid(candidate)
            and ctx.valid(ctx.try(function()
                return candidate.PlayerInventory
            end))
        then
            return candidate
        end
    end
    return nil
end

-- The logs of this tree out of `recent`. The tree spawns each log of the break with itself as the
-- owner. The other logs stay in `recent`: they can belong to another tree that breaks in the same
-- moment. A log of this break appeared just before this call: an older log (one loaded with the
-- save) is dropped without a read, so the many contacts of a falling trunk stay cheap.
---@param tree ABP_ScavengeableTree_C
---@return ABP_TrunkPart_C[] caught
---@return integer dropped
local function takeLogsOf(tree)
    local treeKey = keyOf(tree)
    local now = os.clock()
    local entries, rest = {}, {}
    for _, entry in ipairs(state.recent) do
        if now - entry.t <= RECENT_KEEP_S and ctx.valid(entry.log) then
            local ownerKey = keyOf(ctx.try(function()
                return entry.log:GetOwner()
            end))
            entries[#entries + 1] = { log = entry.log, ownerKey = ownerKey }
            if ownerKey ~= treeKey then rest[#rest + 1] = entry end
        end
    end
    state.recent = rest
    return logic.logsOfTree(entries, treeKey)
end

-- True when the cutter stands within pickup_range_m of the stump.
---@param tree ABP_ScavengeableTree_C
---@param cutter ABP_SGKMasterCharacter_C
---@param count integer the logs of the break, for the log line
---@return boolean
local function cutterInRange(tree, cutter, count)
    local stump = ctx.try(function()
        return tree.Stump:K2_GetComponentLocation()
    end) or ctx.try(function()
        return tree:K2_GetActorLocation()
    end)
    local here = ctx.try(function()
        return cutter:K2_GetActorLocation()
    end)
    if not (stump and here) then
        ctx.warnOnce("positions", "cannot read the tree or player position; logs stay on the ground")
        return false
    end
    local inRange = logic.inRange(here, stump, ctx.config.pickup_range_m)
    local dx, dy, dz = here.X - stump.X, here.Y - stump.Y, here.Z - stump.Z
    ctx.trace(
        string.format(
            "break tree=%s cutter=%s distance=%.1fm logs=%d %s",
            nameOf(tree),
            nameOf(cutter),
            math.sqrt(dx * dx + dy * dy + dz * dz) / 100,
            count,
            inRange and "pickup" or "out of range"
        )
    )
    return inRange
end

-- Runs after the body of each Break Trunk Into Pieces call: the logs of the call are in `recent`.
local function onBreak(self)
    if #state.recent == 0 then return end
    local tree = self:get() ---@type ABP_ScavengeableTree_C
    if not ctx.try(function()
        return tree:HasAuthority()
    end) then return end
    local caught, dropped = takeLogsOf(tree)
    ctx.trace(string.format("break tree=%s logs of the tree=%d other logs=%d", nameOf(tree), #caught, dropped))
    if #caught == 0 then return end
    local cutter = cutterOf(tree)
    if not cutter then
        ctx.warnOnce("cutter", "no player found for a felled tree; its logs stay on the ground")
        return
    end
    if not cutterInRange(tree, cutter, #caught) then return end
    local logs = {}
    for _, lg in ipairs(caught) do
        local name = nameOf(lg)
        local saved = hide(lg)
        if saved then
            state.pending[name] = true
            logs[#logs + 1] = { log = lg, name = name, saved = saved }
        end
    end
    ExecuteWithDelay(PICKUP_DELAY_MS, function()
        ExecuteInGameThread(ctx.guard("pickup", function()
            pickupBreak(logs, cutter)
        end))
    end)
end

-- The player of the inventory that took the log: the pawn of the owner, or the owner.
---@param picked ABP_TrunkPart_C
---@return any
local function pickerOf(picked)
    local inv = ctx.try(function()
        return picked["Player Inventory"]
    end)
    local owner = ctx.valid(inv) and ctx.try(function()
        return inv:GetOwner()
    end) or nil
    if not ctx.valid(owner) then return nil end
    local pawn = ctx.try(function()
        return owner.Pawn
    end)
    return ctx.valid(pawn) and pawn or owner
end

-- Picks up the logs within nearby_range_m of pos, nearest first, until one does not fit.
---@param pos any
---@param pickedKey any
---@param character any
local function nearbyWalk(pos, pickedKey, character)
    local start = os.clock()
    -- The position of each log first; the name and the state only of the logs in range.
    local placed = {}
    local all = logic.liveLogs(state.logs, sameLog) ---@type ABP_TrunkPart_C[]
    for _, lg in ipairs(all) do
        local p = logPos(lg)
        if p then placed[#placed + 1] = { log = lg, key = keyOf(lg), pos = p } end
    end
    local entries = logic.logsInRange(pos, pickedKey, placed, ctx.config.nearby_range_m)
    for _, entry in ipairs(entries) do
        local lg = entry.log
        entry.pending = state.pending[nameOf(lg)]
        entry.collected = ctx.try(function()
            return lg.bCollected
        end) == true
    end
    local nearby = logic.nearbyLogs(pos, entries, ctx.config.nearby_range_m)
    local ms = (os.clock() - start) * 1000
    local taken = 0
    for _, entry in ipairs(nearby) do
        if pickup(entry.log, character) ~= "picked up" then break end
        taken = taken + 1
    end
    ctx.trace(string.format("nearby walk %.2fms logs=%d inRange=%d picked=%d", ms, #placed, #nearby, taken))
end

-- Nearby pickup: runs after the body of Collect Loot, on each pickup of a log.
local function onCollectLoot(self)
    if state.picking or ctx.config.nearby_range_m <= 0 then return end
    local picked = self:get() ---@type ABP_TrunkPart_C
    if not ctx.try(function()
        return picked:HasAuthority()
    end) then return end
    local pickedKey = keyOf(picked)
    local pos = logPos(picked)
    local character = pickerOf(picked)
    if not (pos and ctx.valid(character)) then return end
    -- Deferred: the game is still inside its own interaction of the picked log.
    ExecuteInGameThread(ctx.guard("nearby", function()
        nearbyWalk(pos, pickedKey, character)
    end))
end

-- Arming ------------------------------------------------------------------

-- The tree proves both classes: the tree package imports the log class (game/registry/), so a
-- live tree means that both are in memory, and RegisterHook resolves each function with a hash lookup.
local function armTreeHooks()
    local ok, err = pcall(RegisterHook, PATHS[TREE_CLASS] .. ":Break Trunk Into Pieces", ctx.guard("break", onBreak))
    if ok then
        ctx.trace("tree hook armed (tree seen)")
    else
        ctx.warnOnce("tree hook", "tree hook failed: " .. tostring(err))
    end
    ok, err = pcall(RegisterHook, PATHS[LOG_CLASS] .. ":Collect Loot", ctx.guard("collect loot", onCollectLoot))
    if not ok then ctx.warnOnce("collect hook", "nearby pickup hook failed: " .. tostring(err)) end
end

-- The first new tree queues one arm call and removes the watcher. The flag stops the calls that
-- the loading thread queued before the first one ran.
---@return boolean
local function onFirstTree()
    if state.treeArmed then return true end
    state.treeArmed = true
    ExecuteInGameThread(ctx.guard("arm tree", armTreeHooks))
    return true
end

---@param context FeatureContext
function M.install(context)
    ctx = context
    -- The log watcher stays for the whole session, so the log list also holds each log of the save.
    local ok, err = pcall(NotifyOnNewObject, PATHS[LOG_CLASS], onNewLog)
    if not ok then ctx.warnOnce("watcher", "log watcher failed: " .. tostring(err)) end
    ok, err = pcall(NotifyOnNewObject, PATHS[TREE_CLASS], onFirstTree)
    if not ok then ctx.warnOnce("tree watcher", "tree watcher failed: " .. tostring(err)) end
end

return M
