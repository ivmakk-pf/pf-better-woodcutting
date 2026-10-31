-- Log pickup: the logs of a felled tree go into the inventory of the player who cut it.
-- Runs on the host: every hook acts only where the tree has authority.
--
-- In this UE4SS build a Blueprint hook callback runs after the function body, and a
-- second (post) callback never runs. The code below relies on that order.
local logic = require("bw_log_pickup_logic")

local M = {}

local TREE_CLASS = "BP_ScavengeableTree_C"
local LOG_CLASS = "BP_TrunkPart_C"
local PICKUP_DELAY_MS = 200 -- after Custom Mining & Woodcutting Yield changes the wood (one frame)
local BREAK_WINDOW_S = 0.1 -- logs made in the same break call appear right before its callback
local RECENT_KEEP_S = 0.5

---@param ctx FeatureContext
function M.install(ctx)
    local config, log, warnOnce, trace = ctx.config, ctx.log, ctx.warnOnce, ctx.trace
    local try, valid, guard, classPath = ctx.try, ctx.valid, ctx.guard, ctx.classPath

    ---@param obj any
    ---@return string
    local function nameOf(obj)
        return try(function()
            return obj:GetFName():ToString()
        end) or "?"
    end

    -- nil when the read fails: check the result with valid() before use.
    ---@param lg ABP_TrunkPart_C
    ---@return UStaticMeshComponent
    local function meshOf(lg)
        return try(function()
            return lg.ResourceMesh
        end)
    end

    -- The mesh simulates physics apart from the actor, so its location is where the log lies.
    ---@param lg ABP_TrunkPart_C
    ---@return any position with X, Y, Z, or nil
    local function logPos(lg)
        local mesh = meshOf(lg)
        if valid(mesh) then
            return try(function()
                return mesh:K2_GetComponentLocation()
            end)
        end
        return try(function()
            return lg:K2_GetActorLocation()
        end)
    end

    -- Pickup state --------------------------------------------------------------

    local pending = {} -- log name -> true while it is hidden and its pickup is not resolved
    local recent = {} -- { log, t } of logs made in the last RECENT_KEEP_S
    local picking = false -- true while the mod calls a pickup itself

    -- Append only: a map load can make hundreds of saved logs in one burst. The list is
    -- rebuilt only when its oldest entry is stale, so each log costs one insert.
    local function onNewLog(obj)
        local now = os.clock()
        if recent[1] and now - recent[1].t > RECENT_KEEP_S then recent = {} end
        recent[#recent + 1] = { log = obj, t = now }
    end

    -- Hide and freeze, and show again -----------------------------------------

    -- Each step runs on its own, so one failed step never leaves the others undone.
    local function step(key, fn)
        local ok, err = pcall(fn)
        if not ok then warnOnce(key, key .. ": " .. tostring(err)) end
        return ok
    end

    -- Restore order: transform, physics, collision, visibility. Every new log simulates
    -- physics (probe), so physics always comes back on.
    ---@param lg ABP_TrunkPart_C
    ---@param saved { loc: any, rot: any }
    local function show(lg, saved)
        local mesh = meshOf(lg)
        if valid(mesh) and saved.loc and saved.rot then
            step("show transform", function()
                mesh:K2_SetWorldLocationAndRotation(saved.loc, saved.rot, false, {}, true)
            end)
        end
        if valid(mesh) then step("show physics", function()
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
            loc = valid(mesh) and try(function()
                return mesh:K2_GetComponentLocation()
            end) or nil,
            rot = valid(mesh) and try(function()
                return mesh:K2_GetComponentRotation()
            end) or nil,
        }
        local ok = (
            not valid(mesh)
            or step("hide physics", function()
                mesh:SetSimulatePhysics(false)
            end)
        )
            and step("hide collision", function()
                lg:SetActorEnableCollision(false)
            end)
            and step("hide visibility", function()
                lg:SetActorHiddenInGame(true)
            end)
        if ok then return saved end
        show(lg, saved)
        return nil
    end

    -- The pickup ----------------------------------------------------------------

    -- The game's own pickup path: BeginInteraction checks SGK AllowInteraction and sets bCollected.
    ---@param lg ABP_TrunkPart_C
    ---@param character AActor
    ---@return "picked up"|"shown again"
    local function pickup(lg, character)
        -- The character can be gone by the delayed pickup (a client left): never pass a stale object.
        if not valid(character) then
            warnOnce("pickup character", "the player is gone; the log stays on the ground")
            return "shown again"
        end
        picking = true
        local ok, err = pcall(function()
            lg:BeginInteraction({ ID = FName("Interact") }, character)
        end)
        picking = false
        if not ok then warnOnce("pickup call", "pickup call failed: " .. tostring(err)) end
        return logic.pickupResult({
            valid = valid(lg),
            collected = try(function()
                return lg.bCollected
            end) == true,
        })
    end

    local function pickupBreak(logs, character)
        for _, item in ipairs(logs) do
            local lg, name = item.log, item.name
            if valid(lg) then
                local wood = try(function()
                    return lg["Wood Loot Count"]
                end)
                local result = pickup(lg, character)
                if result ~= "picked up" then
                    show(lg, item.saved)
                    warnOnce("not picked", "a log was not picked up (a game change?); it stays on the ground")
                end
                trace(string.format("log %s wood=%s %s", name, tostring(wood), result))
            end
            pending[name] = nil
        end
    end

    -- The cutter: Damage Cause is the character; its owner is a fallback.
    ---@param tree ABP_ScavengeableTree_C
    ---@return ABP_SGKMasterCharacter_C?
    local function cutterOf(tree)
        local cause = try(function()
            return tree["Damage Cause"]
        end)
        for _, candidate in ipairs({
            cause,
            valid(cause) and try(function()
                return cause:GetOwner()
            end) or nil,
        }) do
            if
                valid(candidate)
                and valid(try(function()
                    return candidate.PlayerInventory
                end))
            then
                return candidate
            end
        end
        return nil
    end

    -- Runs after the body of each Break Trunk Into Pieces call: the logs of the call are in `recent`.
    local function onBreak(self)
        if #recent == 0 then return end
        local tree = self:get() ---@type ABP_ScavengeableTree_C
        if not try(function()
            return tree:HasAuthority()
        end) then return end
        local now = os.clock()
        local caught = {} ---@type ABP_TrunkPart_C[]
        for _, entry in ipairs(recent) do
            if now - entry.t <= BREAK_WINDOW_S and valid(entry.log) then caught[#caught + 1] = entry.log end
        end
        recent = {}
        if #caught == 0 then return end

        local cutter = cutterOf(tree)
        if not cutter then
            warnOnce("cutter", "no player found for a felled tree; its logs stay on the ground")
            return
        end
        local stump = try(function()
            return tree.Stump:K2_GetComponentLocation()
        end) or try(function()
            return tree:K2_GetActorLocation()
        end)
        local here = try(function()
            return cutter:K2_GetActorLocation()
        end)
        if not (stump and here) then
            warnOnce("positions", "cannot read the tree or player position; logs stay on the ground")
            return
        end
        local inRange = logic.inRange(here, stump, config.pickup_range_m)
        local dx, dy, dz = here.X - stump.X, here.Y - stump.Y, here.Z - stump.Z
        trace(
            string.format(
                "break tree=%s cutter=%s distance=%.1fm logs=%d %s",
                nameOf(tree),
                nameOf(cutter),
                math.sqrt(dx * dx + dy * dy + dz * dz) / 100,
                #caught,
                inRange and "pickup" or "out of range"
            )
        )
        if not inRange then return end

        local logs = {}
        for _, lg in ipairs(caught) do
            local name = nameOf(lg)
            local saved = hide(lg)
            if saved then
                pending[name] = true
                logs[#logs + 1] = { log = lg, name = name, saved = saved }
            end
        end
        ExecuteWithDelay(PICKUP_DELAY_MS, function()
            ExecuteInGameThread(guard("pickup", function()
                pickupBreak(logs, cutter)
            end))
        end)
    end

    -- Nearby pickup: runs after the body of Collect Loot, on each pickup of a log.
    local function onCollectLoot(self)
        if picking or config.nearby_range_m <= 0 then return end
        local picked = self:get() ---@type ABP_TrunkPart_C
        if not try(function()
            return picked:HasAuthority()
        end) then return end
        local pickedName = nameOf(picked)
        local pos = logPos(picked)
        local inv = try(function()
            return picked["Player Inventory"]
        end)
        local owner = valid(inv) and try(function()
            return inv:GetOwner()
        end) or nil
        local character = valid(owner)
                and (valid(try(function()
                    return owner.Pawn
                end)) and owner.Pawn or owner)
            or nil
        if not (pos and valid(character)) then return end
        -- Deferred: the game is still inside its own interaction of the picked log.
        ExecuteInGameThread(guard("nearby", function()
            local start = os.clock()
            local entries = {}
            local all = FindAllOf(LOG_CLASS) or {} ---@type ABP_TrunkPart_C[]
            for _, lg in ipairs(all) do
                local name = nameOf(lg)
                if name ~= pickedName and valid(lg) then
                    local p = logPos(lg)
                    if p then
                        entries[#entries + 1] = {
                            log = lg,
                            pos = p,
                            name = name,
                            pending = pending[name],
                            collected = try(function()
                                return lg.bCollected
                            end) == true,
                        }
                    end
                end
            end
            local nearby = logic.nearbyLogs(pos, entries, config.nearby_range_m)
            local ms = (os.clock() - start) * 1000
            local taken = 0
            for _, entry in ipairs(nearby) do
                if pickup(entry.log, character) ~= "picked up" then break end
                taken = taken + 1
            end
            trace(string.format("nearby walk %.2fms logs=%d inRange=%d picked=%d", ms, #entries, #nearby, taken))
        end))
    end

    -- Arming ------------------------------------------------------------------

    local armed = { tree = false, watcher = false, collect = false }

    local function armLogClass(reason)
        if armed.watcher and armed.collect then return end
        local path = classPath(LOG_CLASS)
        if not path then return end
        if not armed.watcher then
            local ok, err = pcall(NotifyOnNewObject, path, onNewLog)
            armed.watcher = true
            if ok then
                trace("log watcher armed (" .. reason .. ")")
            else
                warnOnce("watcher", "log watcher failed: " .. tostring(err))
            end
        end
        if not armed.collect then
            local ok, err = pcall(RegisterHook, path .. ":Collect Loot", guard("collect loot", onCollectLoot))
            armed.collect = true
            if not ok then warnOnce("collect hook", "nearby pickup hook failed: " .. tostring(err)) end
        end
    end

    local function armTree(reason)
        if armed.tree then return end
        local path = classPath(TREE_CLASS)
        if not path then return end
        armed.tree = true
        local lastTree = nil
        local ok, err = pcall(
            RegisterHook,
            path .. ":Break Trunk Into Pieces",
            guard("break", function(self)
                -- The break call repeats on each frame for 1-3 s before the logs appear, so its
                -- first call arms the log watcher in time when the class was not loaded before.
                -- One lookup per tree, not per frame, when the class is missing (a game update).
                if not (armed.watcher and armed.collect) then
                    local tree = nameOf(self:get())
                    if tree ~= lastTree then
                        lastTree = tree
                        armLogClass("break")
                    end
                end
                onBreak(self)
            end)
        )
        if ok then
            trace("tree hook armed (" .. reason .. ")")
        else
            warnOnce("tree hook", "tree hook failed: " .. tostring(err))
        end
    end

    RegisterLoadMapPostHook(function()
        ExecuteInGameThread(guard("map load", function()
            armTree("map load")
            armLogClass("map load")
        end))
    end)

    -- A tree class can load after the map load; a native parent tells when one appears.
    local ok, err = pcall(NotifyOnNewObject, "/Script/Permafrost.Scavengeable", function()
        if armed.tree then return end
        ExecuteInGameThread(guard("arm tree", function()
            armTree("tree seen")
        end))
    end)
    if not ok then warnOnce("scavengeable watcher", "tree watcher failed: " .. tostring(err)) end
end

return M
