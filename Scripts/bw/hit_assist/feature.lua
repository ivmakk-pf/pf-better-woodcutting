-- Hit assist: an axe swing at a tree that does not hit gets one hit through the game's own RPC.
-- Runs on the swinging player's machine, only where the character has authority (solo and host).
--
-- In this UE4SS build a Blueprint hook callback runs after the function body, so a nested call's
-- callback runs first: the next looped swing's SurfaceTrace logs before OnBlendOut, and
-- K2_OnEndAbility before OnInterrupted and OnCancelled. A swing therefore starts at each SurfaceTrace
-- and ends at the next SurfaceTrace or at K2_OnEndAbility. Each tree swing gets one check
-- GRACE_S after its start (the game's own hit lands before that), or at once when the game interrupts
-- or cancels the swing montage (it cannot hit any more then). An interrupt also ends the attack while
-- the button is still held; the mod then restarts it through the weapon's own key-down call, at most
-- MAX_RESTARTS times in a row. Every game call runs from the game-thread queue, never inside a hook
-- callback: a call inside the montage event froze the game.
local logic = require("bw.hit_assist.logic")
local assist = require("bw.hit_assist.assist")
local PATHS = require("bw.paths")

local M = {}

local ABILITY_CLASS = "GA_Attack_MeleePrimary_C"
local WEAPON_CLASS = "BP_MasterMeleeWeapon_C"
local TREE_CLASS = "BP_ScavengeableTree_C"
local FACING_MAX_DEG = 60 -- the SurfaceTrace tree counts as the target only within this angle
local MONTAGE_TASK = "_CDC47AA4495C33C1B7881C9DDD060278"

local ctx ---@type FeatureContext set by install

local state = {
    verbose = false, -- the swing log lines read the game (names, durability): skipped with `verbose` off
    swings = logic.newState(),
    trees = {}, ---@type table<integer, ABP_ScavengeableTree_C> key -> tree, for the checks in flight
    checks = {}, ---@type table<integer, integer> tree key -> number of checks in flight
    lastDamageAt = {}, ---@type table<integer, number> tree key -> time of its last damage
    promptTree = nil, ---@type ABP_ScavengeableTree_C? the tree whose prompt shows
    lastPrompt = nil, ---@type { tree: ABP_ScavengeableTree_C, endedAt: number }? the prompt that went off last
    localCharacter = nil, ---@type any the character of the last local swing, for the Cause of a hit
    lastEnded = nil, ---@type Swing? the swing that K2_OnEndAbility ended last
    hold = logic.newHold(), -- the attack button state, for the restart of an interrupted hold
    restarting = false, -- true while the mod calls the key-down itself
    ---@type table<Swing, { prompt: string?, tree: string?, traceClass: string?, weapon: any, character: any }>
    infoOf = setmetatable({}, { __mode = "k" }),
    armed = {}, ---@type table<string, boolean> class -> its arm call is queued or done
}

---@param swing Swing?
---@param by string
local function logEnd(swing, by)
    if not (swing and state.verbose) then return end
    local info = state.infoOf[swing] or {}
    ctx.trace(
        string.format(
            "swing %d end by=%s prompt=%s traceTarget=%s tree=%s hit=%s assisted=%s %s",
            swing.n,
            by,
            tostring(info.prompt),
            tostring(info.traceClass),
            tostring(info.tree),
            tostring(swing.hit),
            tostring(swing.assisted),
            assist.durabilityLine(info.weapon)
        )
    )
end

---@param swing Swing
local function check(swing)
    local key = swing.target
    assist.check(
        swing,
        key and state.trees[key],
        state.infoOf[swing],
        key and state.lastDamageAt[key],
        state.swings.count
    )
end

-- Hooks -----------------------------------------------------------------------

-- True for a tree whose health is 0 or less (a stump, or a tree that falls), and for a failed read.
-- The stump removal gives a stump a longer prompt reach, so a stump can catch the look-at in front of
-- the tree that the player chops: it is never the prompt tree or the target of a swing.
---@param tree any
---@return boolean
local function isDown(tree)
    local health = ctx.try(function()
        return tree.CurrentHealth
    end)
    return type(health) ~= "number" or health <= 0
end

-- The last prompt tree when the player stands close and faces it (against the trunk the prompt is
-- off and the trace finds nothing), else nil.
---@param character ABP_SGKMasterCharacter_C
---@param from Pos
---@param forward Pos
---@return ABP_ScavengeableTree_C?
local function recentPromptTree(character, from, forward)
    local last = state.lastPrompt
    if not (last and ctx.valid(last.tree)) then return nil end
    local at = last.tree:K2_GetActorLocation() --[[@as Pos]]
    local here = character:K2_GetActorLocation() --[[@as Pos]]
    local dx, dy = at.X - here.X, at.Y - here.Y
    local near = math.sqrt(dx * dx + dy * dy)
    if logic.recentPrompt(last.endedAt, os.clock(), near, logic.facing(from, forward, at, FACING_MAX_DEG)) then
        return last.tree
    end
    return nil
end

-- The tree and the facing check of the SurfaceTrace actor; nil for any other target or tool.
---@param ability UGA_Attack_MeleePrimary_C
---@param character ABP_SGKMasterCharacter_C
---@param traceActor any
---@return ABP_ScavengeableTree_C?
local function targetOf(ability, character, traceActor)
    local cam = character.FirstPersonCamera
    local from = cam:K2_GetComponentLocation() --[[@as Pos]]
    local forward = cam:GetForwardVector() --[[@as Pos]]
    local traceClass = assist.classOf(traceActor)
    local faced = false
    if logic.isTree(traceClass) then
        local at = traceActor:K2_GetActorLocation() --[[@as Pos]]
        faced = logic.facing(from, forward, at, FACING_MAX_DEG)
    end
    local recent = recentPromptTree(character, from, forward)
    local prompt = ctx.valid(state.promptTree) and state.promptTree or nil
    local tree = logic.chooseTarget(prompt, traceActor, traceClass, faced, recent) ---@type ABP_ScavengeableTree_C?
    if not tree then return nil end
    local toolType = ctx.try(function()
        return ability.ItemConfigHoldable.ToolType
    end)
    local required = ctx.try(function()
        return tree:GetRequiredToolType()
    end)
    if not logic.rightTool(toolType, required) then return nil end
    -- A stump is never a swing target: no check, no assist, and no restart of a held attack.
    if isDown(tree) then return nil end
    return tree
end

-- The delayed check of a tree swing, at the assist time of the swing.
---@param swing Swing
---@param key integer
---@param now number
local function scheduleCheck(swing, key, now)
    state.checks[key] = (state.checks[key] or 0) + 1
    local delayMs = math.max(0, math.floor((logic.assistAt(swing) - now) * 1000))
    ExecuteWithDelay(delayMs, function()
        ExecuteInGameThread(function()
            ctx.guard("assist check", check)(swing)
            -- Forget the tree when no check in flight needs it.
            state.checks[key] = state.checks[key] - 1
            if state.checks[key] <= 0 then
                state.checks[key] = nil
                state.trees[key] = nil
            end
        end)
    end)
end

---@param self RemoteUnrealParam
---@param actor RemoteUnrealParam
local function onSurfaceTrace(self, _, actor)
    local ability = self:get() ---@type UGA_Attack_MeleePrimary_C
    if not ability:IsLocallyControlled() then return end
    local character = ability.Character
    if not (ctx.valid(character) and character:HasAuthority()) then return end
    local traceActor = actor:get()
    local tree = targetOf(ability, character, traceActor)
    local key = assist.keyOf(tree)
    local now = os.clock()
    logEnd(logic.startSwing(state.swings, key, now), "next swing")
    local swing = state.swings.open ---@cast swing Swing
    state.infoOf[swing] = {
        prompt = state.verbose and assist.nameOf(state.promptTree) or nil,
        tree = state.verbose and assist.nameOf(tree) or nil,
        traceClass = state.verbose and (assist.classOf(traceActor) or "-") or nil,
        weapon = ability.ItemHoldable,
        character = character,
    }
    state.localCharacter = character
    if not key then return end
    state.trees[key] = tree
    scheduleCheck(swing, key, now)
end

---@param self RemoteUnrealParam
---@param wasCancelled RemoteUnrealParam
local function onEndAbility(self, wasCancelled)
    local ability = self:get() ---@type UGA_Attack_MeleePrimary_C
    if not ability:IsLocallyControlled() then return end
    local swing = logic.endSwing(state.swings)
    -- Also nil when no swing was open, so a later interrupt never acts on an older swing.
    state.lastEnded = swing
    if not state.verbose then return end
    logEnd(
        swing,
        string.format(
            "ability end (cancelled=%s checkFailed=%s held=%s)",
            tostring(wasCancelled:get()),
            tostring(ctx.try(function()
                return ability.CheckFailed
            end)),
            tostring(state.hold.held)
        )
    )
end

-- The restart of an interrupted attack through the weapon's own key-down call.
---@param swing Swing
---@param label string
local function restart(swing, label)
    local weapon = (state.infoOf[swing] or {}).weapon
    -- After the queued check: the new swing's reset then clears the assist's ignore list.
    ExecuteInGameThread(function()
        if not (state.hold.held and ctx.valid(weapon)) then return end
        ctx.trace(string.format("swing %d %s with the button held: restart %d", swing.n, label, state.hold.restarts))
        state.restarting = true
        local ok, err = pcall(function()
            weapon["SGK ClientPrimaryAction"](weapon, true)
        end)
        state.restarting = false
        if not ok then ctx.warnOnce("restart", "restart of the attack failed: " .. tostring(err)) end
    end)
end

-- Runs after the nested K2_OnEndAbility: the interrupted swing is the one that ended last.
---@param label string
---@return fun(self: RemoteUnrealParam)
local function onMontageStopped(label)
    return function(self)
        local ability = self:get() ---@type UGA_Attack_MeleePrimary_C
        if not ability:IsLocallyControlled() then return end
        local swing = state.lastEnded
        state.lastEnded = nil
        if not swing then return end
        ctx.trace("swing " .. swing.n .. " " .. label .. ": check at the next frame")
        -- Never inside the game's montage event: a Server Hit Check call there froze the game
        -- (build 26265449). The game-thread queue runs it one frame later, outside the event.
        ExecuteInGameThread(function()
            ctx.guard("assist check", check)(swing)
        end)
        if not logic.shouldRestart(state.hold, swing) then return end
        logic.onRestart(state.hold)
        restart(swing, label)
    end
end

-- The attack button of the held melee weapon (runs on the swinging player's machine).
---@param keyDown RemoteUnrealParam
local function onPrimaryAction(_, keyDown)
    if keyDown:get() then
        logic.onKeyDown(state.hold, state.restarting)
    else
        logic.onKeyUp(state.hold)
    end
    ctx.trace("attack key " .. (state.hold.held and "down" or "up") .. (state.restarting and " (restart)" or ""))
end

---@param self RemoteUnrealParam
---@param cause RemoteUnrealParam
local function onTreeDamaged(self, _, damage, _, cause)
    local tree = self:get() ---@type ABP_ScavengeableTree_C
    local key = assist.keyOf(tree)
    if not key then return end
    state.lastDamageAt[key] = os.clock()
    -- Only the local player's hit resets the restart limit (on a host, other players hit trees too).
    if state.localCharacter and assist.keyOf(cause:get()) == assist.keyOf(state.localCharacter) then
        logic.onTreeHit(state.hold)
    end
    local open = state.swings.open
    if open and open.target == key then logic.onHit(state.swings) end
    if not state.verbose then return end
    ctx.trace(
        string.format(
            "tree %s damaged by %s%s",
            assist.nameOf(tree),
            tostring(damage:get()),
            open and string.format(" (swing %d +%.2fs)", open.n, os.clock() - open.startedAt) or ""
        )
    )
end

-- The axe's hit window (verbose only, a measurement aid): logs when the window opens and closes in
-- the open swing. A close also comes from ResetSwing and the ability end; the log shows all of them.
---@param traceOn RemoteUnrealParam
local function onCollisionToggle(_, traceOn)
    if not state.verbose then return end
    local open = state.swings.open
    ctx.trace(
        string.format(
            "hit window %s%s",
            traceOn:get() and "open" or "close",
            open and string.format(" (swing %d +%.2fs)", open.n, os.clock() - open.startedAt) or " (no swing)"
        )
    )
end

local function onLookAtStarted(self)
    local tree = self:get()
    state.promptTree = not isDown(tree) and tree or nil
end

local function onLookAtEnded(self)
    local tree = self:get()
    if not isDown(tree) then state.lastPrompt = { tree = tree, endedAt = os.clock() } end
    if assist.keyOf(tree) == assist.keyOf(state.promptTree) then state.promptTree = nil end
end

-- Arming ----------------------------------------------------------------------

local HOOKS = {
    { class = ABILITY_CLASS, fn = "SurfaceTrace", callback = onSurfaceTrace },
    { class = ABILITY_CLASS, fn = "K2_OnEndAbility", callback = onEndAbility },
    { class = WEAPON_CLASS, fn = "SGK ClientPrimaryAction", callback = onPrimaryAction },
    { class = WEAPON_CLASS, fn = "SGK MeleeCollisionToggle", callback = onCollisionToggle },
    { class = ABILITY_CLASS, fn = "OnInterrupted" .. MONTAGE_TASK, callback = onMontageStopped("interrupted") },
    { class = ABILITY_CLASS, fn = "OnCancelled" .. MONTAGE_TASK, callback = onMontageStopped("cancelled") },
    { class = TREE_CLASS, fn = "AUTHORITY_HandleDamaged", callback = onTreeDamaged },
    { class = TREE_CLASS, fn = "HandleLookAtStarted", callback = onLookAtStarted },
    { class = TREE_CLASS, fn = "HandleLookAtEnded", callback = onLookAtEnded },
}

-- The watchers: each class arms its hooks at its first new object.
local WATCHERS = {
    { class = ABILITY_CLASS, reason = "attack seen" },
    { class = WEAPON_CLASS, reason = "weapon seen" },
    { class = TREE_CLASS, reason = "tree seen" },
}

-- Registers the hooks of one class. Its watcher saw a new object of it, so the class is in memory
-- and RegisterHook resolves each function with a hash lookup. A hook that fails (a game update)
-- logs one warning and is not tried again.
---@param class string
---@param reason string
local function armClass(class, reason)
    for _, h in ipairs(HOOKS) do
        if h.class == class then
            local ok, err = pcall(RegisterHook, PATHS[class] .. ":" .. h.fn, ctx.guard(h.fn, h.callback))
            if ok then
                ctx.trace("hit assist hook armed (" .. reason .. ") " .. h.class .. ":" .. h.fn)
            else
                ctx.warnOnce("hook " .. h.fn, "hit assist hook failed: " .. h.fn .. " " .. tostring(err))
            end
        end
    end
end

-- The callback of the watcher of one class: the first new object queues one arm call and removes
-- the watcher. The flag stops the calls that the loading thread queued before the first one ran.
---@param watcher { class: string, reason: string }
---@return fun(): boolean
local function onFirstObject(watcher)
    return function()
        if state.armed[watcher.class] then return true end
        state.armed[watcher.class] = true
        ExecuteInGameThread(ctx.guard("hit assist arm", function()
            armClass(watcher.class, watcher.reason)
        end))
        return true
    end
end

-- A map load arms nothing: it only forgets the trees and the swings of the old world.
local function onMapLoad()
    ExecuteInGameThread(ctx.guard("hit assist map load", function()
        state.promptTree = nil
        state.lastPrompt = nil
        state.lastEnded = nil
        state.lastDamageAt = {}
    end))
end

---@param context FeatureContext
function M.install(context)
    ctx = context
    state.verbose = ctx.config.verbose == true
    assist.init(ctx)
    RegisterLoadMapPostHook(onMapLoad)
    for _, watcher in ipairs(WATCHERS) do
        local ok, err = pcall(NotifyOnNewObject, PATHS[watcher.class], onFirstObject(watcher))
        if not ok then ctx.warnOnce("watcher " .. watcher.class, "hit assist watcher failed: " .. tostring(err)) end
    end
end

return M
