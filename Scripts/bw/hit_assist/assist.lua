-- The assist of the hit assist: a line trace from the camera to the tree, then one hit through the
-- weapon's own RPC (Server Hit Check), as the game's own melee hit. Also the object helpers that the
-- feature shares.
local logic = require("bw.hit_assist.logic")
local UEHelpers = require("UEHelpers")

local M = {}

local TRACE_LENGTH_CM = 300 -- the prompt range: InteractionDistance of BP_PlayerInventory

local ctx ---@type FeatureContext set by init

local state = {
    verbose = false,
    -- The held weapon goes in the ignore list of the trace, as in the game's SurfaceTrace (the
    -- character is ignored already as the world context). Set to false when this UE4SS build cannot
    -- pass the list: the trace then runs with an empty list, as before.
    ignoreWeapon = true,
}

---@param context FeatureContext
function M.init(context)
    ctx = context
    state.verbose = ctx.config.verbose == true
end

---@param obj any
---@return string
function M.nameOf(obj)
    if not ctx.valid(obj) then return "-" end
    return ctx.try(function()
        return obj:GetFName():ToString()
    end) or "?"
end

---@param obj any
---@return string?
function M.classOf(obj)
    if not ctx.valid(obj) then return nil end
    return ctx.try(function()
        return obj:GetClass():GetFName():ToString()
    end)
end

-- The address keys a game object across the different Lua wrappers of hook callbacks.
---@param obj any
---@return integer?
function M.keyOf(obj)
    if not ctx.valid(obj) then return nil end
    return ctx.try(function()
        return obj:GetAddress()
    end)
end

---@param weapon ABP_MasterMeleeWeapon_C?
---@return string
function M.durabilityLine(weapon)
    if not ctx.valid(weapon) then return "durability=-" end
    ---@cast weapon ABP_MasterMeleeWeapon_C
    local item = ctx.try(function()
        return weapon.InventoryItem
    end)
    return string.format(
        "durabilityDecreased=%s durability=%s",
        tostring(ctx.try(function()
            return weapon.DurabilityDecreased
        end)),
        tostring(ctx.valid(item) and ctx.try(function()
            return item:GetDurability(false)
        end))
    )
end

-- The assist ------------------------------------------------------------------

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
    if not state.ignoreWeapon then return run({}) end
    local ok, blocking = pcall(run, { weapon })
    if ok then return blocking end
    -- Only a trace that works with an empty list blames the list: any other error throws here
    -- and keeps the weapon in the list for the next trace.
    local result = run({})
    state.ignoreWeapon = false
    ctx.warnOnce(
        "trace ignore",
        "the trace cannot ignore the weapon, it uses an empty ignore list: " .. tostring(blocking)
    )
    return result
end

-- The ends of the traces to a tree: the look direction at the prompt range, then above the stump.
---@param from Pos
---@param fwd Pos
---@param tree ABP_ScavengeableTree_C
---@return Pos[]
local function traceEnds(from, fwd, tree)
    local ends = {
        {
            X = from.X + fwd.X * TRACE_LENGTH_CM,
            Y = from.Y + fwd.Y * TRACE_LENGTH_CM,
            Z = from.Z + fwd.Z * TRACE_LENGTH_CM,
        },
    }
    local stump = ctx.try(function()
        return tree.Stump:K2_GetComponentLocation()
    end)
    if stump then ends[2] = { X = stump.X, Y = stump.Y, Z = stump.Z + 100 } end
    return ends
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
    local treeKey = M.keyOf(tree)
    for _, to in
        ipairs(traceEnds(from, cam:GetForwardVector() --[[@as Pos]], tree))
    do
        ---@type any the FHitResult that the trace fills
        local hit = {}
        local blocking = lineTrace(ksl, character, weapon, from, to, weapon.MeleeTraceChannel, hit)
        local ref = ctx.try(function()
            return hit.HitObjectHandle.ReferenceObject:Get()
        end)
        local owner = ref
        if (M.classOf(ref) or ""):find("Component") then
            owner = ctx.try(function()
                return ref:GetOwner()
            end)
        end
        if blocking and M.keyOf(owner) == treeKey then
            local handle = hit.HitObjectHandle ---@type any
            handle.ReferenceObject = tree
            return hit
        end
    end
    return nil
end

-- A short text in the game's own HUD notification; a test aid, used only with `verbose` on.
---@param text string
---@param character any the world context of the HUD lookup: the swinging character
local function showOnScreen(text, character)
    local ok, err = pcall(function()
        local lib = StaticFindObject("/Script/Permafrost.Default__PermaFunctionLibrary") ---@cast lib UPermaFunctionLibrary
        local hud = lib:GetMainHUD_ByWorld(character) ---@cast hud UGeneralHUDWidget
        hud:ShowTextNotification(FText("BetterWoodcutting: " .. text), 1.0)
    end)
    if not ok then ctx.warnOnce("screen", "screen message failed: " .. tostring(err)) end
end

---@param swing Swing
local function assist(swing, tree, info)
    local weapon, character = info and info.weapon, info and info.character
    if not (ctx.valid(tree) and ctx.valid(weapon) and ctx.valid(character)) then return end
    ---@cast tree ABP_ScavengeableTree_C
    ---@cast weapon ABP_MasterMeleeWeapon_C
    ---@cast character ABP_SGKMasterCharacter_C
    local scavenged = ctx.try(function()
        return tree.bScavenged
    end)
    local health = ctx.try(function()
        return tree.CurrentHealth
    end)
    if type(health) ~= "number" then health = nil end
    if logic.treeDown(scavenged, health) then
        ctx.trace(
            string.format(
                "swing %d no assist: the tree is down (bScavenged=%s health=%s)",
                swing.n,
                tostring(scavenged),
                tostring(health)
            )
        )
        return
    end
    local hit = traceTree(character, weapon, tree)
    if not hit then
        ctx.trace("swing " .. swing.n .. " no assist: the line trace did not reach the tree")
        return
    end
    logic.markAssisted(swing)
    local before = state.verbose and M.durabilityLine(weapon)
    -- HitCheck takes durability only while DurabilityDecreased is false; ResetSwing clears it,
    -- as it does at the start of each swing.
    if weapon.DurabilityDecreased then weapon:ResetSwing() end
    weapon["Server Hit Check"](weapon, { hit })
    if not state.verbose then return end
    showOnScreen("hit assist: swing " .. swing.n, character)
    ctx.trace(
        string.format(
            "swing %d assisted tree=%s before: %s after: %s",
            swing.n,
            M.nameOf(tree),
            before,
            M.durabilityLine(weapon)
        )
    )
end

-- Runs the assist of a swing when it still needs one; an error leaves the swing vanilla.
---@param swing Swing
---@param tree ABP_ScavengeableTree_C?
---@param info { weapon: any, character: any }?
---@param lastDamageAt number? the time of the last damage of the tree
---@param count integer the swing count of the swing state
function M.check(swing, tree, info, lastDamageAt, count)
    if not logic.needsAssist(swing, lastDamageAt, count, os.clock()) then return end
    local ok, err = pcall(assist, swing, tree, info)
    if not ok then ctx.warnOnce("assist", "hit assist failed, the swing stays vanilla: " .. tostring(err)) end
end

return M
