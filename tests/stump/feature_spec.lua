-- Glue specs of the stump removal: the prompt, the hold end, the removal, and the arming.
local fakes = require("fakes")
local PATHS = require("bw.paths")

local TREE = PATHS.BP_ScavengeableTree_C .. ":"
local HUD = PATHS.UW_HUD_C .. ":"
local FINALIZE = "/Script/Permafrost.InteractionInterface:FinalizeInteraction"
local WOOD = "/Game/Permafrost/Blueprints/Items/DataAsset_Items/Resources/DA_Resource_Wood.DA_Resource_Wood"
local WOOD_ACTOR = "/Game/Permafrost/Blueprints/Items/WorldItems/Resources/BP_Wood_WI.BP_Wood_WI_C"
local LIBRARY = "/Script/Permafrost.Default__PermaFunctionLibrary"

local P = fakes.param

-- An FName as the game gives it: a value with ToString.
local function fname(s)
    return {
        ToString = function()
            return s
        end,
    }
end

-- A TArray property as the game gives it: ForEach with a wrapped element.
local function array(items)
    return {
        ForEach = function(_, fn)
            for i, item in ipairs(items) do
                fn(i, P(item))
            end
        end,
    }
end

-- The game calls FinalizeInteraction with no parameter buffer: a get() crashed the game natively.
local NO_BUFFER = {
    get = function()
        error("get() on a parameter of FinalizeInteraction")
    end,
}

local env, w

local function tagName(tag)
    local name = tag.TagName
    return type(name) == "string" and name or name:ToString()
end

local function newTree(name, health)
    local action = {
        ID = fname("Break"),
        Name = "Break",
        InteractionTime = 0,
        Tags = {
            GameplayTags = array({
                { TagName = fname("Interaction.Input.LMB") },
                { TagName = fname("Interaction.Break") },
            }),
        },
    }
    local stump = fakes.object({ class = "StaticMeshComponent", visible = true, collision = 3 })
    stump.SetVisibility = function(self, on, propagate)
        self.visible = on
        self.propagate = propagate
    end
    stump.SetCollisionEnabled = function(self, kind)
        self.collision = kind
    end
    return fakes.object({
        class = "BP_ScavengableTree_102_C",
        name = name,
        CurrentHealth = health,
        action = action,
        PossibleActions = { Actions = array({ action }) },
        Stump = stump,
        authority = true,
        HasAuthority = function(self)
            return self.authority
        end,
        GetActorScale3D = function()
            return { X = 1, Y = 1.5, Z = 1 }
        end,
    })
end

local function newWorld()
    local world = { given = {}, loads = 0, classLoads = 0, screen = {} }
    world.axe = fakes.object({ class = "BP_Iron_Axe_Refined_Holdable_C" })
    world.knife = fakes.object({ class = "BP_Iron_Knife_Holdable_C" })
    world.equipment = {
        HeldItem = { ItemActor = world.axe },
        AddItemAmount = function(_, amount, notify, drop)
            if world.failAdd then error("add boom") end
            world.given[#world.given + 1] = { item = amount.Item, amount = amount.Amount, notify = notify, drop = drop }
            return amount.Amount
        end,
    }
    world.player = fakes.object({
        class = "BP_SGKMasterCharacter_C",
        EquipmentComponent = world.equipment,
        IsLocallyControlled = function()
            return true
        end,
    })
    world.ksl = {
        MakeSoftObjectPath = function(_, path)
            return { path = path }
        end,
        Conv_SoftObjPathToSoftObjRef = function(_, path)
            return { soft = path.path }
        end,
        Conv_SoftObjectReferenceToObject = function(_, soft)
            return env.objects[soft.soft]
        end,
        LoadAsset = function(_, context, soft)
            world.loads = world.loads + 1
            world.loadContext, world.loadSoft = context, soft
        end,
        MakeSoftClassPath = function(_, path)
            return { path = path }
        end,
        Conv_SoftClassPathToSoftClassRef = function(_, path)
            return { class = path.path }
        end,
        Conv_SoftClassReferenceToClass = function(_, soft)
            return env.objects[soft.class]
        end,
        LoadAssetClass = function(_, _, soft)
            world.classLoads = world.classLoads + 1
            world.classLoadSoft = soft
        end,
    }
    world.stump = newTree("Stump1", 0)
    world.hud = fakes.object({ class = "UW_HUD_C" })
    return world
end

local function install(config)
    env = fakes.install()
    w = newWorld()
    env.objects[WOOD] = fakes.object({ class = "UItemConfig_Resource" })
    env.objects[WOOD_ACTOR] = fakes.object({ class = "BlueprintGeneratedClass" })
    env.objects[LIBRARY] = fakes.object({
        GetMainHUD_ByWorld = function()
            return fakes.object({
                ShowTextNotification = function(_, message)
                    w.screen[#w.screen + 1] = message
                end,
            })
        end,
    })
    package.loaded["UEHelpers"] = {
        GetKismetSystemLibrary = function()
            return w.ksl
        end,
    }
    package.loaded["bw.stump.feature"] = nil
    local ctx = require("bw.core.context").new("BetterWoodcutting")
    ctx.config = config or { stump_removal = true, stump_hold_s = 2, verbose = true }
    require("bw.stump.feature").install(ctx)
end

-- A world load: the game makes the trees and the HUD.
local function worldLoad()
    env.spawn(w.player)
    env.spawn(w.stump)
    env.spawn(w.hud)
end

local function allowed(tree)
    return env.hooks[TREE .. "IsInteractionAllowed"](P(tree))
end

local function lookAt(tree)
    env.hooks[TREE .. "HandleLookAtStarted"](P(tree))
end

local function lookAway(tree)
    env.hooks[TREE .. "HandleLookAtEnded"](P(tree))
end

local function hudAction(id)
    env.hooks[HUD .. "Interaction Params Change"](P(w.hud), P({ ID = fname(id) }))
end

local function finalize()
    env.hooks[FINALIZE](NO_BUFFER)
end

-- The player looks at the stump, the prompt shows, and the hold of F ends.
local function holdOn(tree)
    lookAt(tree)
    allowed(tree)
    hudAction("BW_RemoveStump")
    finalize()
end

local function lines(pattern)
    local n = 0
    for _, line in ipairs(env.printed) do
        if line:find(pattern) then n = n + 1 end
    end
    return n
end

describe("stump removal", function()
    after_each(function()
        fakes.restore()
        package.loaded["UEHelpers"] = nil
        package.loaded["bw.stump.feature"] = nil
    end)

    describe("the arming", function()
        before_each(function()
            install()
        end)

        it("registers the hold end hook at the install, as a native function", function()
            assert.is_function(env.hooks[FINALIZE])
        end)

        it("arms the tree hooks from its tree watcher in one queued call, and the watcher stays", function()
            env.holdGameThread = true
            for i = 1, 1000 do
                env.spawn(newTree("T" .. i, 100))
            end
            assert.are.equal(1, #env.queued)
            env.runGameThread()
            assert.is_function(env.hooks[TREE .. "IsInteractionAllowed"])
            assert.is_function(env.hooks[TREE .. "HandleLookAtStarted"])
            assert.are.equal(1, #env.watchers[PATHS.BP_ScavengeableTree_C])
        end)

        it("arms the HUD hook from the HUD watcher, which then goes", function()
            env.spawn(w.hud)
            assert.is_function(env.hooks[HUD .. "Interaction Params Change"])
            assert.are.equal(0, #env.watchers[PATHS.UW_HUD_C])
        end)

        it("starts no load of the wood item when it is in memory", function()
            worldLoad()
            assert.are.equal(0, w.loads)
        end)

        it(
            "starts the latent load of the class of a dropped wood item at the first tree when it is not in memory",
            function()
                env.objects[WOOD_ACTOR] = nil
                worldLoad()
                assert.are.equal(1, w.classLoads)
                assert.are.equal(0, w.loads)
            end
        )

        it("starts no load when neither a player nor the first tree is still there", function()
            env.objects[WOOD] = nil
            env.holdGameThread = true
            local tree = env.spawn(newTree("Gone", 100))
            tree.destroyed = true
            env.runGameThread()
            assert.are.equal(0, w.loads)
            assert.are.equal(0, w.classLoads)
        end)

        it("starts the latent load of the wood item at the first tree when it is not in memory", function()
            env.objects[WOOD] = nil
            worldLoad()
            assert.are.equal(1, w.loads)
            assert.are.same({ soft = WOOD }, w.loadSoft)
        end)
    end)

    describe("the prompt", function()
        before_each(function()
            install()
            worldLoad()
        end)

        it("is allowed for a stump with an axe in hand, and the stump's action becomes the hold of F", function()
            assert.is_true(allowed(w.stump))
            local action = w.stump.action
            assert.are.equal("BW_RemoveStump", action.ID)
            assert.are.equal("Remove stump", action.Name)
            assert.are.equal(2, action.InteractionTime)
            local tags = {}
            action.Tags.GameplayTags:ForEach(function(_, element)
                tags[#tags + 1] = tagName(element:get())
            end)
            assert.are.same({ "Interaction.Input.Default", "Interaction.Interact" }, tags)
        end)

        it("changes the action of a stump only at the first call", function()
            allowed(w.stump)
            w.stump.action.InteractionTime = 7
            assert.is_true(allowed(w.stump))
            assert.are.equal(7, w.stump.action.InteractionTime)
        end)

        it("changes the action of a new stump at the address of a changed one", function()
            allowed(w.stump)
            local reused = newTree("Reused", 0)
            reused.GetAddress = w.stump.GetAddress
            assert.is_true(allowed(reused))
            assert.are.equal("BW_RemoveStump", reused.action.ID)
        end)

        it("takes the hold time of the config", function()
            install({ stump_removal = true, stump_hold_s = 4.5, verbose = false })
            worldLoad()
            allowed(w.stump)
            assert.are.equal(4.5, w.stump.action.InteractionTime)
        end)

        it("leaves the game's value for a standing tree", function()
            local tree = newTree("Standing", 100)
            assert.is_nil(allowed(tree))
            assert.are.equal("Break", tree.action.Name)
        end)

        it("leaves the game's value for a stump with no axe in hand", function()
            w.equipment.HeldItem.ItemActor = w.knife
            assert.is_nil(allowed(w.stump))
            w.equipment.HeldItem.ItemActor = nil
            assert.is_nil(allowed(w.stump))
            assert.are.equal("Break", w.stump.action.Name)
        end)

        it("is not allowed for a removed stump", function()
            w.stump.CurrentHealth = -1
            assert.is_false(allowed(w.stump))
        end)

        it("reaches a stump from 2.5 m, the game's default reach", function()
            assert.are.equal(250, env.hooks[TREE .. "GetInteractionDistance"](P(w.stump)))
        end)

        it("leaves the reach of a standing tree and of a removed stump to the game", function()
            local reach = env.hooks[TREE .. "GetInteractionDistance"]
            assert.is_nil(reach(P(newTree("Standing", 100))))
            assert.is_nil(reach(P(newTree("Removed", -1))))
        end)
    end)

    describe("the end of the hold", function()
        before_each(function()
            install()
            worldLoad()
        end)

        it("marks the stump, gives the wood of one log, and hides the stump, with no parameter read", function()
            holdOn(w.stump)
            assert.are.equal(-1, w.stump.CurrentHealth)
            assert.are.equal(1, #w.given)
            assert.are.same({ soft = WOOD }, w.given[1].item)
            assert.are.equal(5, w.given[1].amount)
            assert.is_true(w.given[1].notify and w.given[1].drop)
            assert.is_false(w.stump.Stump.visible)
            assert.is_false(w.stump.Stump.propagate)
            assert.are.equal(0, w.stump.Stump.collision)
            assert.are.equal(1, lines("stump removed Stump1 wood=5"))
            assert.are.equal(0, lines("WARN"))
        end)

        it("reads the axe and gives the wood of the local player, not of another player", function()
            local otherGiven = {}
            local other = fakes.object({
                class = "BP_SGKMasterCharacter_C",
                IsLocallyControlled = function()
                    return false
                end,
                EquipmentComponent = {
                    HeldItem = { ItemActor = w.knife },
                    AddItemAmount = function(_, amount)
                        otherGiven[#otherGiven + 1] = amount
                    end,
                },
            })
            install()
            env.spawn(other)
            worldLoad()
            holdOn(w.stump)
            assert.are.equal(1, #w.given)
            assert.are.equal(0, #otherGiven)
        end)

        it("does nothing for the hold of another action (a box, a carcass)", function()
            lookAt(w.stump)
            allowed(w.stump)
            hudAction("unlock")
            finalize()
            assert.are.equal(0, w.stump.CurrentHealth)
            assert.are.equal(0, #w.given)
        end)

        it("does nothing when the looked-at stump is gone", function()
            lookAt(w.stump)
            w.stump.destroyed = true
            hudAction("BW_RemoveStump")
            finalize()
            assert.are.equal(0, #w.given)
        end)

        it("removes the stump of a tree that fell while the player looked at it", function()
            local tree = env.spawn(newTree("Felled", 100))
            lookAt(tree) -- the look-at starts while the tree stands
            tree.CurrentHealth = 0 -- the last hit; the tree falls with no new look-at
            allowed(tree)
            hudAction("BW_RemoveStump")
            finalize()
            assert.are.equal(-1, tree.CurrentHealth)
            assert.are.equal(1, #w.given)
        end)

        it("never removes an older stump after the look-at moved to another tree", function()
            lookAt(w.stump)
            lookAway(w.stump)
            local other = env.spawn(newTree("Other", 100))
            lookAt(other)
            allowed(w.stump)
            hudAction("BW_RemoveStump")
            finalize()
            assert.are.equal(0, w.stump.CurrentHealth)
            assert.are.equal(0, #w.given)
        end)

        it("forgets the stump when the look-at ends", function()
            lookAt(w.stump)
            allowed(w.stump)
            lookAway(w.stump)
            hudAction("BW_RemoveStump")
            finalize()
            assert.are.equal(0, w.stump.CurrentHealth)
        end)

        it("does nothing for a standing tree that the player looked at", function()
            local tree = newTree("Standing", 100)
            holdOn(tree)
            assert.are.equal(100, tree.CurrentHealth)
            assert.are.equal(0, #w.given)
        end)

        it("does nothing on a machine without authority over the stump", function()
            w.stump.authority = false
            holdOn(w.stump)
            assert.are.equal(0, w.stump.CurrentHealth)
            assert.are.equal(0, #w.given)
        end)

        it("does nothing when the axe left the hand during the hold", function()
            lookAt(w.stump)
            allowed(w.stump)
            hudAction("BW_RemoveStump")
            w.equipment.HeldItem.ItemActor = nil
            finalize()
            assert.are.equal(0, w.stump.CurrentHealth)
        end)

        it("does nothing while the wood item is not in memory, warns once, and starts its load again", function()
            env.objects[WOOD] = nil
            local loads = w.loads
            holdOn(w.stump)
            holdOn(w.stump)
            assert.are.equal(0, w.stump.CurrentHealth)
            assert.are.equal(0, #w.given)
            assert.are.equal(loads + 2, w.loads)
            assert.are.equal(1, lines("WARN .*wood item"))
            assert.are.same({ "Remove stump: try again", "Remove stump: try again" }, w.screen)
            env.objects[WOOD] = fakes.object({ class = "UItemConfig_Resource" })
            holdOn(w.stump)
            assert.are.equal(-1, w.stump.CurrentHealth)
            assert.are.equal(1, #w.given)
        end)

        it("does nothing while the class of a dropped wood item is not in memory, and starts its load", function()
            env.objects[WOOD_ACTOR] = nil
            local loads = w.classLoads
            holdOn(w.stump)
            assert.are.equal(0, w.stump.CurrentHealth)
            assert.are.equal(0, #w.given)
            assert.are.equal(loads + 1, w.classLoads)
            assert.are.same({ class = WOOD_ACTOR }, w.classLoadSoft)
            assert.are.same({ "Remove stump: try again" }, w.screen)
        end)

        it("gives no wood a second time after an error behind the marker", function()
            w.failAdd = true
            holdOn(w.stump)
            assert.are.equal(-1, w.stump.CurrentHealth)
            assert.is_false(w.stump.Stump.visible)
            w.failAdd = false
            holdOn(w.stump)
            assert.are.equal(0, #w.given)
        end)

        it("looks up no /Game/ object and walks no object list", function()
            holdOn(w.stump)
            assert.are.same({ gameLookups = 0, findAllOf = 0 }, env.count)
        end)
    end)

    describe("the load hide", function()
        before_each(function()
            install()
        end)

        it("arms the two setup hooks of the tree with the other tree hooks", function()
            worldLoad()
            assert.is_function(env.hooks[TREE .. "PostLoadObjectFromNamesAndValues"])
            assert.is_function(env.hooks[TREE .. "ReceiveBeginPlay"])
        end)

        it("hides a marked stump after each setup of the game, which shows it again", function()
            worldLoad()
            local marked = newTree("Marked", -1)
            env.hooks[TREE .. "ReceiveBeginPlay"](P(marked))
            assert.is_false(marked.Stump.visible)
            marked.Stump.visible = true -- PostLoadObjectFromNamesAndValues sets up the stump again
            marked.Stump.collision = 3
            env.hooks[TREE .. "PostLoadObjectFromNamesAndValues"](P(marked))
            assert.is_false(marked.Stump.visible)
            assert.are.equal(0, marked.Stump.collision)
        end)

        it("leaves a stump and a standing tree as the game set them up", function()
            worldLoad()
            local tree = newTree("Standing", 100)
            env.hooks[TREE .. "PostLoadObjectFromNamesAndValues"](P(tree))
            env.hooks[TREE .. "ReceiveBeginPlay"](P(w.stump))
            assert.is_true(tree.Stump.visible and w.stump.Stump.visible)
        end)

        it("checks a burst of new trees once, after a delay, and hides each marked stump of it", function()
            local trees = {}
            for i = 1, 2000 do
                trees[i] = env.spawn(newTree("T" .. i, i % 100 == 0 and -1 or 100))
            end
            assert.are.equal(1, #env.delays)
            env.runDelays()
            local hidden = 0
            for _, tree in ipairs(trees) do
                if not tree.Stump.visible then hidden = hidden + 1 end
            end
            assert.are.equal(20, hidden)
            assert.are.equal(1, lines("stump check [%d.]+ms trees=2000 hidden=20"))
        end)

        it("empties the list at each check, so the next burst checks only its own trees", function()
            env.spawn(newTree("A", -1))
            env.runDelays()
            env.spawn(newTree("B", 100))
            assert.are.equal(1, #env.delays)
            env.runDelays()
            assert.are.equal(1, lines("stump check [%d.]+ms trees=1 hidden=0"))
        end)

        it("hides the other marked stumps of a burst after one hide fails", function()
            local broken = env.spawn(newTree("Broken", -1))
            broken.Stump.SetVisibility = function()
                error("hide boom")
            end
            local marked = env.spawn(newTree("Marked", -1))
            env.runDelays()
            assert.is_false(marked.Stump.visible)
            assert.are.equal(1, lines("WARN .*not hidden"))
            assert.are.equal(1, lines("stump check [%d.]+ms trees=2 hidden=1"))
        end)

        it("drops a tree that is gone before the check", function()
            local gone = env.spawn(newTree("Gone", -1))
            gone.destroyed = true
            env.runDelays()
            assert.is_true(gone.Stump.visible)
            assert.are.equal(1, lines("stump check [%d.]+ms trees=0 hidden=0"))
            assert.are.equal(0, lines("WARN"))
        end)
    end)
end)
