-- Stump removal: with an axe in hand, a stump gets the game's own hold prompt, "Remove stump". At the
-- end of the hold the stump is marked in the save (a health of -1), the player gets the wood of one
-- log, and the stump is hidden with no collision.
--
-- The prompt and the hold are the game's own: IsInteractionAllowed of the tree says yes for a stump,
-- and the stump's own "Break" action becomes a timed action of the interact key (F). A hold of F runs
-- the game's interaction ability, whose timer calls FinalizeInteraction on the stump at the end.
-- Runs on the host, for the host player: the hold end acts only where the stump has authority.
local logic = require("bw.stump.logic")
local PATHS = require("bw.paths")
local UEHelpers = require("UEHelpers")

local M = {}

local TREE_CLASS = "BP_ScavengeableTree_C"
local HUD_CLASS = "UW_HUD_C"
local AXE_CLASS = "BP_MasterAxe_C" -- the parent of each axe class (BP_MasterAxe.hpp)
local ACTION_ID = "BW_RemoveStump"
local FINALIZE = "/Script/Permafrost.InteractionInterface:FinalizeInteraction"
local WOOD_PATH = "/Game/Permafrost/Blueprints/Items/DataAsset_Items/Resources/DA_Resource_Wood.DA_Resource_Wood"
local WOOD_ACTOR_PATH = "/Game/Permafrost/Blueprints/Items/WorldItems/Resources/BP_Wood_WI.BP_Wood_WI_C"
-- The input tag picks the key icon of the prompt (UW_HintsList): Default is the interact key.
local TAG_CHANGES = {
    ["Interaction.Input.LMB"] = "Interaction.Input.Default",
    ["Interaction.Break"] = "Interaction.Interact",
}
local CHAIN_MAX = 12
local STUMP_REACH_CM = 250 -- the default reach of the game's detection ability (UDetectionAbility)
local CHECK_DELAY_MS = 1000 -- the load check of a burst runs once its trees have their saved values

-- Untyped: the Kismet calls take structs that UE4SS makes from Lua values.
---@return any
local function kismet()
    return UEHelpers.GetKismetSystemLibrary()
end

local ctx ---@type FeatureContext set by install

local state = {
    lookStump = nil, ---@type any the tree that the look-at reached last, nil after its look-at ended
    hudAction = nil, ---@type string? the ID of the current action of the HUD
    treeArmed = false,
    hudArmed = false,
    trees = {}, ---@type table<any, any> address -> each new tree whose load check has not run yet
    checkQueued = false,
    characters = {}, ---@type any[] each player character that the game made in this session
    woodSoft = nil, ---@type any the soft reference of the wood item, made once
    woodActorSoft = nil, ---@type any the soft class reference of a dropped wood item, made once
    loadId = 0,
}

---@param obj any
---@return string
local function nameOf(obj)
    if not ctx.valid(obj) then return "-" end
    return ctx.try(function()
        return obj:GetFName():ToString()
    end) or "?"
end

---@param obj any
---@return any
local function keyOf(obj)
    if not ctx.valid(obj) then return nil end
    return ctx.try(function()
        return obj:GetAddress()
    end)
end

-- The character of the local player, from the characters that the character watcher saw. No
-- UEHelpers.GetPlayer: it walks the object array (FindAllOf of PlayerController) at each call.
---@return any
local function player()
    for _, character in ipairs(state.characters) do
        if
            ctx.valid(character)
            and ctx.try(function()
                return character:IsLocallyControlled()
            end)
        then
            return character
        end
    end
    return nil
end

---@param character any
local function onNewCharacter(character)
    local kept = { character }
    for _, known in ipairs(state.characters) do
        if ctx.valid(known) then kept[#kept + 1] = known end
    end
    state.characters = kept
end

-- The health of a tree, nil when the read fails or gives no number.
---@param tree any
---@return number?
local function healthOf(tree)
    local h = ctx.try(function()
        return tree.CurrentHealth
    end)
    if type(h) ~= "number" then return nil end
    return h
end

-- The text of an FName (the fakes and a written tag give a plain string).
---@param name any
---@return string?
local function textOf(name)
    if type(name) == "string" then return name end
    return ctx.try(function()
        return name:ToString()
    end)
end

-- True when the class chain of the item in the hand of the local player holds the axe class.
-- The chain needs no item config read: those fields are soft pointers, and a soft field read
-- crashed in this UE4SS build.
---@return boolean
local function axeInHand()
    local actor = ctx.try(function()
        return player().EquipmentComponent.HeldItem.ItemActor
    end)
    if not ctx.valid(actor) then return false end
    local cls = ctx.try(function()
        return actor:GetClass()
    end)
    for _ = 1, CHAIN_MAX do
        if not ctx.valid(cls) then return false end
        if textOf(ctx.try(function()
            return cls:GetFName()
        end)) == AXE_CLASS then return true end
        cls = ctx.try(function()
            return cls:GetSuperStruct()
        end)
    end
    return false
end

-- The wood item ------------------------------------------------------------------

---@return any
local function woodSoft()
    if not state.woodSoft then
        local ksl = kismet()
        state.woodSoft = ksl:Conv_SoftObjPathToSoftObjRef(ksl:MakeSoftObjectPath(WOOD_PATH))
    end
    return state.woodSoft
end

-- The class of a dropped wood item (ClassForSpawnInWorld of the wood item): a full inventory drops
-- the wood that does not fit, and the drop loads this class synchronously (DropItem).
---@return any
local function woodActorSoft()
    if not state.woodActorSoft then
        local ksl = kismet()
        state.woodActorSoft = ksl:Conv_SoftClassPathToSoftClassRef(ksl:MakeSoftClassPath(WOOD_ACTOR_PATH))
    end
    return state.woodActorSoft
end

-- AddItemAmount loads the item synchronously, and its drop of the overflow loads the class of the
-- dropped item, and a synchronous load from Lua can deadlock while the game streams the world
-- (AGENTS.md): the removal runs only while both are in memory.
---@return boolean item in memory
---@return boolean class in memory
local function woodInMemory()
    local item = ctx.try(function()
        return kismet():Conv_SoftObjectReferenceToObject(woodSoft())
    end)
    local class = ctx.try(function()
        return kismet():Conv_SoftClassReferenceToClass(woodActorSoft())
    end)
    return ctx.valid(item), ctx.valid(class)
end

---@return table the FLatentActionInfo of one latent load
local function latentInfo(context)
    state.loadId = state.loadId + 1
    return { Linkage = 0, UUID = state.loadId, ExecutionFunction = FName("None"), CallbackTarget = context }
end

-- The latent loads of the wood item and of the class of a dropped one, for each that is not in
-- memory (asynchronous, outside the Lua lock).
---@param context any a live object of the world
local function startWoodLoad(context)
    local item, class = woodInMemory()
    local ok, err = pcall(function()
        if not item then kismet():LoadAsset(context, woodSoft(), nil, latentInfo(context)) end
        if not class then kismet():LoadAssetClass(context, woodActorSoft(), nil, latentInfo(context)) end
    end)
    if ok then
        ctx.trace(string.format("stump wood load started (item %s, class %s)", tostring(not item), tostring(not class)))
    else
        ctx.warnOnce("wood load", "the load of the wood item failed: " .. tostring(err))
    end
end

-- A short text in the game's own HUD notification.
---@param text string
local function showOnScreen(text)
    local ok, err = pcall(function()
        local lib = StaticFindObject("/Script/Permafrost.Default__PermaFunctionLibrary") ---@cast lib UPermaFunctionLibrary
        local hud = lib:GetMainHUD_ByWorld(player()) ---@cast hud UGeneralHUDWidget
        hud:ShowTextNotification(FText(text), 2.0)
    end)
    if not ok then ctx.warnOnce("stump screen", "screen message failed: " .. tostring(err)) end
end

-- The prompt ---------------------------------------------------------------------

-- Changes the stump's own "Break" action in place: only these fields of the existing element, so
-- no new struct and no soft pointer. The action itself tells whether it is changed: a key by
-- address would skip a new tree that took the address of a changed one.
---@param tree any
local function changeAction(tree)
    local action = nil
    tree.PossibleActions.Actions:ForEach(function(_, element)
        if not action then action = element:get() end
    end)
    if not action or textOf(action.ID) == ACTION_ID then return end
    action.ID = FName(ACTION_ID)
    action.Name = FText("Remove stump")
    action.InteractionTime = ctx.config.stump_hold_s
    action.Tags.GameplayTags:ForEach(function(_, element)
        local tag = element:get()
        local to = TAG_CHANGES[textOf(tag.TagName) or ""]
        if to then tag.TagName = FName(to) end
    end)
    ctx.trace("stump action changed " .. nameOf(tree))
end

-- The return value replaces the game's: true for a stump with an axe in hand, false for a removed
-- stump, and nil (the game's own value) for any other tree.
---@param self RemoteUnrealParam
---@return boolean?
local function onAllowed(self)
    local tree = self:get()
    local h = healthOf(tree)
    if logic.isRemoved(h) then return false end
    if not logic.isStump(h) or not axeInHand() then return nil end
    changeAction(tree)
    return true
end

-- The prompt reach of a stump: the tree's own reach (1 m) is measured from the camera, and the top of
-- a stump is low, so the eyes are often farther than 1 m from it. A standing tree keeps its reach.
---@param self RemoteUnrealParam
---@return number?
local function onReach(self)
    if logic.isStump(healthOf(self:get())) then return STUMP_REACH_CM end
    return nil
end

-- The look-at keeps each tree, also a standing one: a tree that falls while the player looks at it
-- becomes a stump with no new look-at. The end of the hold checks the health.
---@param self RemoteUnrealParam
local function onLookAt(self)
    state.lookStump = self:get()
end

-- The end of the look-at forgets the tree, so a hold never acts on a tree that the player left.
---@param self RemoteUnrealParam
local function onLookAway(self)
    if keyOf(self:get()) == keyOf(state.lookStump) then state.lookStump = nil end
end

---@param params RemoteUnrealParam
local function onHudParams(_, params)
    state.hudAction = ctx.try(function()
        return textOf(params:get().ID)
    end)
end

-- The removal --------------------------------------------------------------------

---@param tree any
local function hideStump(tree)
    local stump = tree.Stump
    stump:SetVisibility(false, false)
    stump:SetCollisionEnabled(0)
end

-- The marker first, then the wood, then the hide: an error after the marker leaves a stump that
-- the next load hides, and never gives the wood twice.
---@param tree any
local function remove(tree)
    local wood = logic.logWood(tree:GetActorScale3D())
    tree.CurrentHealth = -1
    local ok, err = pcall(function()
        player().EquipmentComponent:AddItemAmount({ Item = woodSoft(), Amount = wood }, true, true)
    end)
    if not ok then ctx.warnOnce("stump wood", "the wood of a removed stump was not given: " .. tostring(err)) end
    ok, err = pcall(hideStump, tree)
    if not ok then ctx.warnOnce("stump hide", "a removed stump was not hidden: " .. tostring(err)) end
    ctx.trace(string.format("stump removed %s wood=%d", nameOf(tree), wood))
end

-- Runs before each FinalizeInteraction of any actor (a box, a carcass, a stump). It reads no
-- parameter: the game calls this interface function with no parameter buffer, and a get() there
-- crashed the game in UE4SS. The target is the stump that the player looks at.
local function onFinalize()
    if state.hudAction ~= ACTION_ID then return end
    local tree = state.lookStump
    if not ctx.valid(tree) or not logic.isStump(healthOf(tree)) then return end
    if not ctx.try(function()
        return tree:HasAuthority()
    end) then return end
    if not axeInHand() then return end
    local item, class = woodInMemory()
    if not (item and class) then
        ctx.warnOnce("wood item", "the wood item is not loaded yet; the stump stays, hold again")
        showOnScreen("Remove stump: try again")
        startWoodLoad(tree)
        return
    end
    state.lookStump = nil
    remove(tree)
end

-- The load hide ------------------------------------------------------------------

-- After the game's own setup of a tree, which shows the stump again (SetupDepleted): a marked stump
-- hides. Runs after the Blueprint body, as each Blueprint hook of this UE4SS build.
---@param self RemoteUnrealParam
local function onSetup(self)
    local tree = self:get()
    if logic.isRemoved(healthOf(tree)) then hideStump(tree) end
end

-- The deferred check of a burst of new trees: it hides each marked stump whose setup ran before the
-- setup hooks were armed, and empties the list.
local function checkTrees()
    local start = os.clock()
    local list = state.trees
    state.trees = {}
    state.checkQueued = false
    local count, hidden = 0, 0
    for key, tree in pairs(list) do
        if ctx.valid(tree) and keyOf(tree) == key then
            count = count + 1
            if logic.isRemoved(healthOf(tree)) then
                -- One failed hide leaves the other stumps of the burst to hide.
                local ok, err = pcall(hideStump, tree)
                if ok then
                    hidden = hidden + 1
                else
                    ctx.warnOnce("stump hide", "a removed stump was not hidden: " .. tostring(err))
                end
            end
        end
    end
    ctx.trace(string.format("stump check %.2fms trees=%d hidden=%d", (os.clock() - start) * 1000, count, hidden))
end

---@param tree any
local function listTree(tree)
    local key = keyOf(tree)
    if not key then return end
    state.trees[key] = tree
    if state.checkQueued then return end
    state.checkQueued = true
    ExecuteWithDelay(CHECK_DELAY_MS, function()
        ExecuteInGameThread(ctx.guard("stump check", checkTrees))
    end)
end

-- Arming -------------------------------------------------------------------------

---@param fn string
---@param callback function
local function hookTree(fn, callback)
    ctx.hook("stump " .. fn, PATHS[TREE_CLASS] .. ":" .. fn, callback)
end

---@param tree any the first new tree, a live object of the world
local function armTree(tree)
    hookTree("IsInteractionAllowed", onAllowed)
    hookTree("HandleLookAtStarted", onLookAt)
    hookTree("HandleLookAtEnded", onLookAway)
    hookTree("GetInteractionDistance", onReach)
    hookTree("PostLoadObjectFromNamesAndValues", onSetup)
    hookTree("ReceiveBeginPlay", onSetup)
    ctx.trace("stump hooks armed (tree seen)")
    local item, class = woodInMemory()
    -- The world context of the latent loads: the player, else the first tree when it is still there.
    -- With neither, the first hold that waits for the wood starts the loads.
    local context = player() or (ctx.valid(tree) and tree or nil)
    if context and not (item and class) then startWoodLoad(context) end
end

-- The tree watcher stays for the whole session: each new tree goes into the list of the load check,
-- and its first call arms the tree hooks.
local function onNewTree(tree)
    listTree(tree)
    if state.treeArmed then return end
    state.treeArmed = true
    ExecuteInGameThread(ctx.guard("stump arm", function()
        armTree(tree)
    end))
end

---@return boolean
local function onNewHud()
    if state.hudArmed then return true end
    state.hudArmed = true
    ExecuteInGameThread(ctx.guard("stump arm hud", function()
        ctx.hook("stump hud", PATHS[HUD_CLASS] .. ":Interaction Params Change", onHudParams)
    end))
    return true
end

---@param context FeatureContext
function M.install(context)
    ctx = context
    ctx.hook("stump finalize", FINALIZE, onFinalize, { required = true })
    local ok, err = pcall(NotifyOnNewObject, PATHS[TREE_CLASS], onNewTree)
    if not ok then error("stump tree watcher failed: " .. tostring(err)) end
    ok, err = pcall(NotifyOnNewObject, PATHS[HUD_CLASS], onNewHud)
    if not ok then error("stump HUD watcher failed: " .. tostring(err)) end
    ok, err = pcall(NotifyOnNewObject, PATHS.BP_SGKMasterCharacter_C, onNewCharacter)
    if not ok then error("stump character watcher failed: " .. tostring(err)) end
end

return M
