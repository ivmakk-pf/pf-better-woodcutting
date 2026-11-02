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
local logic = require("bw_hit_assist_logic")
local UEHelpers = require("UEHelpers")

local M = {}

local ABILITY_CLASS = "GA_Attack_MeleePrimary_C"
local WEAPON_CLASS = "BP_MasterMeleeWeapon_C"
local TREE_CLASS = "BP_ScavengeableTree_C"
local FACING_MAX_DEG = 60 -- the SurfaceTrace tree counts as the target only within this angle
local TRACE_LENGTH_CM = 300 -- the prompt range: InteractionDistance of BP_PlayerInventory

---@param ctx FeatureContext
function M.install(ctx)
    local warnOnce, trace = ctx.warnOnce, ctx.trace
    local try, valid, guard, classPath = ctx.try, ctx.valid, ctx.guard, ctx.classPath
    -- The swing log lines read the game (names, durability): skip those reads with `verbose` off.
    local verbose = ctx.config.verbose == true

    ---@param obj any
    ---@return string
    local function nameOf(obj)
        if not valid(obj) then return "-" end
        return try(function()
            return obj:GetFName():ToString()
        end) or "?"
    end

    ---@param obj any
    ---@return string?
    local function classOf(obj)
        if not valid(obj) then return nil end
        return try(function()
            return obj:GetClass():GetFName():ToString()
        end)
    end

    -- The address keys a game object across the different Lua wrappers of hook callbacks.
    ---@param obj any
    ---@return integer?
    local function keyOf(obj)
        if not valid(obj) then return nil end
        return try(function()
            return obj:GetAddress()
        end)
    end

    -- Set in the arming section below; the swing hook uses them to arm a class that loaded late.
    local allArmed ---@type fun(): boolean
    local armAll ---@type fun(reason: string, onlyClass: string?)
    local armTriedAtSwing = false
    local state = logic.newState()
    local trees = {} ---@type table<integer, ABP_ScavengeableTree_C> key -> tree, for the checks in flight
    local checks = {} ---@type table<integer, integer> tree key -> number of checks in flight
    local lastDamageAt = {} ---@type table<integer, number> tree key -> time of its last damage
    local promptTree = nil ---@type ABP_ScavengeableTree_C? the tree whose prompt shows
    local lastPrompt = nil ---@type { tree: ABP_ScavengeableTree_C, endedAt: number }? the prompt that went off last
    local localCharacter = nil ---@type any the character of the last local swing, for the Cause of a hit
    local lastEnded = nil ---@type Swing? the swing that K2_OnEndAbility ended last
    local hold = logic.newHold() -- the attack button state, for the restart of an interrupted hold
    local restarting = false -- true while the mod calls the key-down itself
    ---@type table<Swing, { prompt: string?, tree: string?, traceClass: string?, weapon: any, character: any }>
    local infoOf = setmetatable({}, { __mode = "k" })

    ---@param weapon ABP_MasterMeleeWeapon_C?
    ---@return string
    local function durabilityLine(weapon)
        if not valid(weapon) then return "durability=-" end
        ---@cast weapon ABP_MasterMeleeWeapon_C
        local item = try(function()
            return weapon.InventoryItem
        end)
        return string.format(
            "durabilityDecreased=%s durability=%s",
            tostring(try(function()
                return weapon.DurabilityDecreased
            end)),
            tostring(valid(item) and try(function()
                return item:GetDurability(false)
            end))
        )
    end

    ---@param swing Swing?
    ---@param by string
    local function logEnd(swing, by)
        if not (swing and verbose) then return end
        local info = infoOf[swing] or {}
        trace(
            string.format(
                "swing %d end by=%s prompt=%s traceTarget=%s tree=%s hit=%s assisted=%s %s",
                swing.n,
                by,
                tostring(info.prompt),
                tostring(info.traceClass),
                tostring(info.tree),
                tostring(swing.hit),
                tostring(swing.assisted),
                durabilityLine(info.weapon)
            )
        )
    end

    -- The assist ------------------------------------------------------------------

    -- The held weapon goes in the ignore list of the trace, as in the game's SurfaceTrace (the
    -- character is ignored already as the world context). Set to false when this UE4SS build cannot
    -- pass the list: the trace then runs with an empty list, as before.
    local ignoreWeapon = true

    -- One line trace that fills `hit`; true when it found a blocking hit.
    local function lineTrace(ksl, character, weapon, from, to, channel, hit)
        local color = { R = 0, G = 0, B = 0, A = 0 }
        local function run(ignore)
            return ksl:LineTraceSingle(
                character,
                from --[[@as FVector]],
                to --[[@as FVector]],
                channel,
                true,
                ignore,
                0,
                hit,
                true,
                color,
                color,
                0.0
            )
        end
        if not ignoreWeapon then return run({}) end
        local ok, blocking = pcall(run, { weapon })
        if ok then return blocking end
        -- Only a trace that works with an empty list blames the list: any other error throws here
        -- and keeps the weapon in the list for the next trace.
        local result = run({})
        ignoreWeapon = false
        warnOnce(
            "trace ignore",
            "the trace cannot ignore the weapon, it uses an empty ignore list: " .. tostring(blocking)
        )
        return result
    end

    -- A line trace from the camera that hits the tree (look direction, then the stump). The length is
    -- the prompt range, longer than the game's own swing trace. A Lua trace gives the hit component in
    -- HitObjectHandle.ReferenceObject, and HitCheck finds no actor there: the tree actor goes in, as in
    -- the game's own melee hits.
    ---@param character ABP_SGKMasterCharacter_C
    ---@param weapon ABP_MasterMeleeWeapon_C
    ---@param tree ABP_ScavengeableTree_C
    ---@return table? hit
    local function traceTree(character, weapon, tree)
        local ksl = UEHelpers.GetKismetSystemLibrary()
        local cam = character.FirstPersonCamera
        local from = cam:K2_GetComponentLocation() --[[@as Pos]]
        local fwd = cam:GetForwardVector() --[[@as Pos]]
        local treeKey = keyOf(tree)
        local channel = weapon.MeleeTraceChannel
        local ends = {
            {
                X = from.X + fwd.X * TRACE_LENGTH_CM,
                Y = from.Y + fwd.Y * TRACE_LENGTH_CM,
                Z = from.Z + fwd.Z * TRACE_LENGTH_CM,
            },
        }
        local stump = try(function()
            return tree.Stump:K2_GetComponentLocation()
        end)
        if stump then ends[2] = { X = stump.X, Y = stump.Y, Z = stump.Z + 100 } end
        for _, to in ipairs(ends) do
            ---@type any the FHitResult that the trace fills
            local hit = {}
            local blocking = lineTrace(ksl, character, weapon, from, to, channel, hit)
            local ref = try(function()
                return hit.HitObjectHandle.ReferenceObject:Get()
            end)
            local owner = ref
            if (classOf(ref) or ""):find("Component") then
                owner = try(function()
                    return ref:GetOwner()
                end)
            end
            if blocking and keyOf(owner) == treeKey then
                local handle = hit.HitObjectHandle ---@type any
                handle.ReferenceObject = tree
                return hit
            end
        end
        return nil
    end

    -- A short text in the game's own HUD notification; a test aid, used only with `verbose` on.
    ---@param text string
    local function showOnScreen(text)
        local ok, err = pcall(function()
            local lib = StaticFindObject("/Script/Permafrost.Default__PermaFunctionLibrary") ---@cast lib UPermaFunctionLibrary
            local hud = lib:GetMainHUD_ByWorld(UEHelpers.GetPlayer()) ---@cast hud UGeneralHUDWidget
            hud:ShowTextNotification(FText("BetterWoodcutting: " .. text), 1.0)
        end)
        if not ok then warnOnce("screen", "screen message failed: " .. tostring(err)) end
    end

    ---@param swing Swing
    local function assist(swing)
        local info = infoOf[swing]
        local tree = swing.target and trees[swing.target]
        local weapon, character = info and info.weapon, info and info.character
        if not (valid(tree) and valid(weapon) and valid(character)) then return end
        ---@cast tree ABP_ScavengeableTree_C
        ---@cast weapon ABP_MasterMeleeWeapon_C
        ---@cast character ABP_SGKMasterCharacter_C
        local scavenged = try(function()
            return tree.bScavenged
        end)
        if logic.treeDown(scavenged) then
            trace("swing " .. swing.n .. " no assist: the tree is down (bScavenged=" .. tostring(scavenged) .. ")")
            return
        end
        local hit = traceTree(character, weapon, tree)
        if not hit then
            trace("swing " .. swing.n .. " no assist: the line trace did not reach the tree")
            return
        end
        logic.markAssisted(swing)
        local before = verbose and durabilityLine(weapon)
        -- HitCheck takes durability only while DurabilityDecreased is false; ResetSwing clears it,
        -- as it does at the start of each swing.
        if weapon.DurabilityDecreased then weapon:ResetSwing() end
        weapon["Server Hit Check"](weapon, { hit })
        if not verbose then return end
        showOnScreen("hit assist: swing " .. swing.n)
        trace(
            string.format(
                "swing %d assisted tree=%s before: %s after: %s",
                swing.n,
                nameOf(tree),
                before,
                durabilityLine(weapon)
            )
        )
    end

    ---@param swing Swing
    local function check(swing)
        local key = swing.target
        if not logic.needsAssist(swing, key and lastDamageAt[key], state.count, os.clock()) then return end
        local ok, err = pcall(assist, swing)
        if not ok then warnOnce("assist", "hit assist failed, the swing stays vanilla: " .. tostring(err)) end
    end

    -- Hooks -----------------------------------------------------------------------

    -- The tree and the facing check of the SurfaceTrace actor; nil for any other target or tool.
    ---@param ability UGA_Attack_MeleePrimary_C
    ---@param character ABP_SGKMasterCharacter_C
    ---@param traceActor any
    ---@return ABP_ScavengeableTree_C?
    local function targetOf(ability, character, traceActor)
        local cam = character.FirstPersonCamera
        local from = cam:K2_GetComponentLocation() --[[@as Pos]]
        local forward = cam:GetForwardVector() --[[@as Pos]]
        local traceClass = classOf(traceActor)
        local faced = false
        if logic.isTree(traceClass) then
            local at = traceActor:K2_GetActorLocation() --[[@as Pos]]
            faced = logic.facing(from, forward, at, FACING_MAX_DEG)
        end
        -- Against the trunk: the prompt is off and the trace finds nothing; the last prompt tree may still count.
        local recent = nil
        if lastPrompt and valid(lastPrompt.tree) then
            local at = lastPrompt.tree:K2_GetActorLocation() --[[@as Pos]]
            local here = character:K2_GetActorLocation() --[[@as Pos]]
            local dx, dy = at.X - here.X, at.Y - here.Y
            local near = math.sqrt(dx * dx + dy * dy)
            local ok = logic.recentPrompt(
                lastPrompt.endedAt,
                os.clock(),
                near,
                logic.facing(from, forward, at, FACING_MAX_DEG)
            )
            if ok then recent = lastPrompt.tree end
        end
        local prompt = valid(promptTree) and promptTree or nil
        local tree = logic.chooseTarget(prompt, traceActor, traceClass, faced, recent) ---@type ABP_ScavengeableTree_C?
        if not tree then return nil end
        local toolType = try(function()
            return ability.ItemConfigHoldable.ToolType
        end)
        local required = try(function()
            return tree:GetRequiredToolType()
        end)
        if not logic.rightTool(toolType, required) then return nil end
        return tree
    end

    ---@param self RemoteUnrealParam
    ---@param actor RemoteUnrealParam
    local function onSurfaceTrace(self, _, actor)
        -- The weapon class can load after the other hooks armed: a swing proves it is in memory,
        -- so one try is enough (a class missing after a game update costs no lookups per swing).
        if not armTriedAtSwing and not allArmed() then
            armTriedAtSwing = true
            ExecuteInGameThread(guard("hit assist arm", function()
                armAll("swing")
            end))
        end
        local ability = self:get() ---@type UGA_Attack_MeleePrimary_C
        if not ability:IsLocallyControlled() then return end
        local character = ability.Character
        if not (valid(character) and character:HasAuthority()) then return end
        local traceActor = actor:get()
        local tree = targetOf(ability, character, traceActor)
        local key = keyOf(tree)
        local now = os.clock()
        logEnd(logic.startSwing(state, key, now), "next swing")
        local swing = state.open ---@cast swing Swing
        infoOf[swing] = {
            prompt = verbose and nameOf(promptTree) or nil,
            tree = verbose and nameOf(tree) or nil,
            traceClass = verbose and (classOf(traceActor) or "-") or nil,
            weapon = ability.ItemHoldable,
            character = character,
        }
        localCharacter = character
        if not key then return end
        trees[key] = tree
        checks[key] = (checks[key] or 0) + 1
        local delayMs = math.max(0, math.floor((logic.assistAt(swing) - now) * 1000))
        ExecuteWithDelay(delayMs, function()
            ExecuteInGameThread(function()
                guard("assist check", check)(swing)
                -- Forget the tree when no check in flight needs it.
                checks[key] = checks[key] - 1
                if checks[key] <= 0 then
                    checks[key] = nil
                    trees[key] = nil
                end
            end)
        end)
    end

    ---@param self RemoteUnrealParam
    ---@param wasCancelled RemoteUnrealParam
    local function onEndAbility(self, wasCancelled)
        local ability = self:get() ---@type UGA_Attack_MeleePrimary_C
        if not ability:IsLocallyControlled() then return end
        local swing = logic.endSwing(state)
        -- Also nil when no swing was open, so a later interrupt never acts on an older swing.
        lastEnded = swing
        if not verbose then return end
        logEnd(
            swing,
            string.format(
                "ability end (cancelled=%s checkFailed=%s held=%s)",
                tostring(wasCancelled:get()),
                tostring(try(function()
                    return ability.CheckFailed
                end)),
                tostring(hold.held)
            )
        )
    end

    -- Runs after the nested K2_OnEndAbility: the interrupted swing is the one that ended last.
    ---@param label string
    ---@return fun(self: RemoteUnrealParam)
    local function onMontageStopped(label)
        return function(self)
            local ability = self:get() ---@type UGA_Attack_MeleePrimary_C
            if not ability:IsLocallyControlled() then return end
            local swing = lastEnded
            lastEnded = nil
            if not swing then return end
            trace("swing " .. swing.n .. " " .. label .. ": check at the next frame")
            -- Never inside the game's montage event: a Server Hit Check call there froze the game
            -- (build 26265449). The game-thread queue runs it one frame later, outside the event.
            ExecuteInGameThread(function()
                guard("assist check", check)(swing)
            end)
            if not logic.shouldRestart(hold, swing) then return end
            logic.onRestart(hold)
            local weapon = (infoOf[swing] or {}).weapon
            -- After the queued check: the new swing's reset then clears the assist's ignore list.
            ExecuteInGameThread(function()
                if not (hold.held and valid(weapon)) then return end
                trace(string.format("swing %d %s with the button held: restart %d", swing.n, label, hold.restarts))
                restarting = true
                local ok, err = pcall(function()
                    weapon["SGK ClientPrimaryAction"](weapon, true)
                end)
                restarting = false
                if not ok then warnOnce("restart", "restart of the attack failed: " .. tostring(err)) end
            end)
        end
    end

    -- The attack button of the held melee weapon (runs on the swinging player's machine).
    ---@param keyDown RemoteUnrealParam
    local function onPrimaryAction(_, keyDown)
        if keyDown:get() then
            logic.onKeyDown(hold, restarting)
        else
            logic.onKeyUp(hold)
        end
        trace("attack key " .. (hold.held and "down" or "up") .. (restarting and " (restart)" or ""))
    end

    ---@param self RemoteUnrealParam
    ---@param cause RemoteUnrealParam
    local function onTreeDamaged(self, _, damage, _, cause)
        local tree = self:get() ---@type ABP_ScavengeableTree_C
        local key = keyOf(tree)
        if not key then return end
        lastDamageAt[key] = os.clock()
        -- Only the local player's hit resets the restart limit (on a host, other players hit trees too).
        if localCharacter and keyOf(cause:get()) == keyOf(localCharacter) then logic.onTreeHit(hold) end
        if state.open and state.open.target == key then logic.onHit(state) end
        if not verbose then return end
        local open = state.open
        trace(
            string.format(
                "tree %s damaged by %s%s",
                nameOf(tree),
                tostring(damage:get()),
                open and string.format(" (swing %d +%.2fs)", open.n, os.clock() - open.startedAt) or ""
            )
        )
    end

    -- The axe's hit window (verbose only, a measurement aid): logs when the window opens and closes in
    -- the open swing. A close also comes from ResetSwing and the ability end; the log shows all of them.
    ---@param traceOn RemoteUnrealParam
    local function onCollisionToggle(_, traceOn)
        if not verbose then return end
        local open = state.open
        trace(
            string.format(
                "hit window %s%s",
                traceOn:get() and "open" or "close",
                open and string.format(" (swing %d +%.2fs)", open.n, os.clock() - open.startedAt) or " (no swing)"
            )
        )
    end

    -- Arming (D7) -------------------------------------------------------------------

    local MONTAGE_TASK = "_CDC47AA4495C33C1B7881C9DDD060278"
    local HOOKS = {
        { class = ABILITY_CLASS, fn = "SurfaceTrace", callback = onSurfaceTrace },
        { class = ABILITY_CLASS, fn = "K2_OnEndAbility", callback = onEndAbility },
        { class = WEAPON_CLASS, fn = "SGK ClientPrimaryAction", callback = onPrimaryAction },
        { class = WEAPON_CLASS, fn = "SGK MeleeCollisionToggle", callback = onCollisionToggle },
        { class = ABILITY_CLASS, fn = "OnInterrupted" .. MONTAGE_TASK, callback = onMontageStopped("interrupted") },
        { class = ABILITY_CLASS, fn = "OnCancelled" .. MONTAGE_TASK, callback = onMontageStopped("cancelled") },
        { class = TREE_CLASS, fn = "AUTHORITY_HandleDamaged", callback = onTreeDamaged },
        {
            class = TREE_CLASS,
            fn = "HandleLookAtStarted",
            callback = function(self)
                promptTree = self:get()
            end,
        },
        {
            class = TREE_CLASS,
            fn = "HandleLookAtEnded",
            callback = function(self)
                local tree = self:get()
                lastPrompt = { tree = tree, endedAt = os.clock() }
                if keyOf(tree) == keyOf(promptTree) then promptTree = nil end
            end,
        },
    }
    local armedCount = 0

    allArmed = function()
        return armedCount == #HOOKS
    end

    local function treesArmed()
        for _, h in ipairs(HOOKS) do
            if h.class == TREE_CLASS and not h.armed then return false end
        end
        return true
    end

    -- onlyClass limits the arming to the hooks of one class. A class that is not in memory costs a
    -- scan of all objects in StaticFindObject, so a caller that knows which class loaded passes it.
    armAll = function(reason, onlyClass)
        if armedCount == #HOOKS then return end
        for _, h in ipairs(HOOKS) do
            if not h.armed and (onlyClass == nil or h.class == onlyClass) then
                local path = classPath(h.class)
                if path then
                    h.armed = true
                    armedCount = armedCount + 1
                    local ok, err = pcall(RegisterHook, path .. ":" .. h.fn, guard(h.fn, h.callback))
                    if ok then
                        trace("hit assist hook armed (" .. reason .. ") " .. h.class .. ":" .. h.fn)
                    else
                        warnOnce("hook " .. h.fn, "hit assist hook failed: " .. h.fn .. " " .. tostring(err))
                    end
                end
            end
        end
    end

    RegisterLoadMapPostHook(function()
        ExecuteInGameThread(guard("hit assist map load", function()
            promptTree = nil
            lastPrompt = nil
            lastEnded = nil
            lastDamageAt = {}
            armAll("map load")
        end))
    end)

    -- The ability and weapon classes load with the held item; a new ability object tells when.
    local ok, err = pcall(NotifyOnNewObject, "/Script/Permafrost.GameplayAbility_Base", function()
        if armedCount == #HOOKS then return end
        ExecuteInGameThread(guard("hit assist arm", function()
            armAll("ability seen")
        end))
    end)
    if not ok then warnOnce("ability watcher", "hit assist watcher failed: " .. tostring(err)) end

    -- The tree class can load after the map load and after the first swing; a native parent tells
    -- when a tree (or a rock or a bush) appears. Only a new tree arms, and only the tree hooks: its
    -- class is then in memory, so the lookup never misses (a miss scans all objects). One arm call
    -- waits at a time, so a streaming burst queues one, not one per object. After the tree hooks
    -- arm, each new object costs one check.
    local treesDone, treeArmQueued = false, false
    ok, err = pcall(NotifyOnNewObject, "/Script/Permafrost.Scavengeable", function(obj)
        if treesDone or treeArmQueued then return end
        if not logic.isTree(classOf(obj)) then return end
        treesDone = treesArmed()
        if treesDone then return end
        treeArmQueued = true
        ExecuteInGameThread(guard("hit assist arm", function()
            treeArmQueued = false
            armAll("tree seen", TREE_CLASS)
        end))
    end)
    if not ok then warnOnce("tree watcher", "hit assist tree watcher failed: " .. tostring(err)) end
end

return M
