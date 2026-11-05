-- Glue specs of the hit assist: the swing hooks, the delayed check, the restart, and the arming.
local fakes = require("fakes")
local PATHS = require("bw.paths")

local GA = PATHS.GA_Attack_MeleePrimary_C .. ":"
local WEAPON = PATHS.BP_MasterMeleeWeapon_C .. ":"
local TREE = PATHS.BP_ScavengeableTree_C .. ":"
local MONTAGE = "_CDC47AA4495C33C1B7881C9DDD060278"
local INTERRUPTED = GA .. "OnInterrupted" .. MONTAGE
local LIBRARY = "/Script/Permafrost.Default__PermaFunctionLibrary"

local P = fakes.param

local function V(x, y, z)
    return { X = x, Y = y, Z = z }
end

local function vecFn(x, y, z)
    return function()
        return V(x, y, z)
    end
end

local realClock = os.clock
local env, w

-- The world of one spec: the player, a tree, a rock, the axe, the ability, the HUD, and the trace.
local function newWorld()
    local world = { now = 100, serverHits = {}, screen = {}, traceIgnores = {}, traceThrown = false, restarts = 0 }
    world.character = fakes.object({
        class = "BP_SGKMasterCharacter_C",
        name = "Char",
        HasAuthority = function()
            return true
        end,
        K2_GetActorLocation = vecFn(500, 0, 0),
    })
    world.character.FirstPersonCamera = fakes.object({
        class = "CameraComponent",
        K2_GetComponentLocation = vecFn(0, 0, 150),
        GetForwardVector = vecFn(1, 0, 0),
    })
    world.tree = fakes.object({
        class = "BP_ScavengableTree_102_C",
        name = "HTree",
        bScavenged = false,
        CurrentHealth = 100,
        K2_GetActorLocation = vecFn(120, 0, 0),
        Stump = fakes.object({ class = "StaticMeshComponent", K2_GetComponentLocation = vecFn(120, 0, 0) }),
        GetRequiredToolType = function()
            return 1
        end,
    })
    world.rock =
        fakes.object({ class = "BP_ScavengeableRock_C", name = "Rock", K2_GetActorLocation = vecFn(120, 0, 0) })
    world.weapon = fakes.object({
        class = "BP_Iron_Axe_Refined_Holdable_C",
        name = "Axe",
        MeleeTraceChannel = 3,
        DurabilityDecreased = true,
        resets = 0,
        InventoryItem = fakes.object({
            GetDurability = function()
                return 290
            end,
        }),
        ResetSwing = function(self)
            self.resets = self.resets + 1
            self.DurabilityDecreased = false
        end,
        ["Server Hit Check"] = function(_, hits)
            world.serverHits[#world.serverHits + 1] = hits[1]
        end,
    })
    -- The weapon's key-down call: the hook callback runs inside it, as in the game.
    world.weapon["SGK ClientPrimaryAction"] = function(self, down)
        world.restarts = world.restarts + 1
        local h = env.hooks[WEAPON .. "SGK ClientPrimaryAction"]
        if h then h(P(self), P(down)) end
    end
    world.ability = fakes.object({
        class = "GA_Attack_MeleePrimary_C",
        Character = world.character,
        ItemHoldable = world.weapon,
        ItemConfigHoldable = { ToolType = 1 },
        IsLocallyControlled = function()
            return true
        end,
    })
    return world
end

local function fakeHelpers(world)
    return {
        GetKismetSystemLibrary = function()
            return {
                LineTraceSingle = function(_, _, _, _, _, _, ignore, _, hit)
                    world.traceIgnores[#world.traceIgnores + 1] = ignore
                    -- The first call with an ignore list throws, as a UE4SS build that cannot pass a
                    -- Lua table as a TArray of actors would.
                    if #ignore > 0 and world.throwOnIgnore and not world.traceThrown then
                        world.traceThrown = true
                        error("ignore list boom")
                    end
                    local trunk = fakes.object({
                        class = "StaticMeshComponent",
                        GetOwner = function()
                            return world.tree
                        end,
                    })
                    hit.HitObjectHandle = {
                        ReferenceObject = {
                            Get = function()
                                return trunk
                            end,
                        },
                    }
                    return not world.traceMiss
                end,
            }
        end,
    }
end

-- Installs the hit assist with this config, then arms it as a map load does.
local function install(config)
    env = fakes.install()
    w = newWorld()
    for _, path in pairs(PATHS) do
        env.objects[path] = fakes.object({ class = "BlueprintGeneratedClass" })
    end
    env.objects[LIBRARY] = fakes.object({
        GetMainHUD_ByWorld = function()
            return fakes.object({
                ShowTextNotification = function(_, text)
                    w.screen[#w.screen + 1] = text
                end,
            })
        end,
    })
    package.loaded["UEHelpers"] = fakeHelpers(w)
    package.loaded["bw.hit_assist.feature"] = nil
    package.loaded["bw.hit_assist.assist"] = nil
    local ctx = require("bw.core.context").new("BetterWoodcutting")
    ctx.config = config or { verbose = false }
    require("bw.hit_assist.feature").install(ctx)
    -- A fake clock: the swing helpers move w.now.
    ---@diagnostic disable-next-line: duplicate-set-field
    os.clock = function()
        return w.now
    end
end

-- A world load: the game makes the objects of the world, then the map-load callbacks run.
local function mapLoad()
    for _, obj in ipairs({ w.tree, w.rock, w.weapon, w.ability }) do
        env.spawn(obj)
    end
    for _, fn in ipairs(env.loadMap.post) do
        fn()
    end
end

local function swing(target)
    w.now = w.now + 0.5
    env.hooks[GA .. "SurfaceTrace"](P(w.ability), P(true), P(target), P(3))
end

local function endAbility(cancelled)
    env.hooks[GA .. "K2_OnEndAbility"](P(w.ability), P(cancelled))
end

-- The checks run 0.8 s after the swing start.
local function runChecks()
    w.now = w.now + 0.8
    env.runDelays()
end

local function lookAt(tree)
    env.hooks[TREE .. "HandleLookAtStarted"](P(tree))
end

local function lookAway(tree)
    env.hooks[TREE .. "HandleLookAtEnded"](P(tree))
end

local function damaged(tree)
    env.hooks[TREE .. "AUTHORITY_HandleDamaged"](P(tree), P({}), P(34), P(1), P(w.character))
end

local function interrupt(target)
    swing(target)
    endAbility(true)
    env.hooks[INTERRUPTED](P(w.ability))
end

local function key(down)
    env.hooks[WEAPON .. "SGK ClientPrimaryAction"](P(w.weapon), P(down))
end

local function lines(pattern)
    local n = 0
    for _, line in ipairs(env.printed) do
        if line:find(pattern) then n = n + 1 end
    end
    return n
end

describe("hit assist", function()
    after_each(function()
        os.clock = realClock
        fakes.restore()
        package.loaded["UEHelpers"] = nil
        package.loaded["bw.hit_assist.feature"] = nil
        package.loaded["bw.hit_assist.assist"] = nil
    end)

    describe("a look-at of a stump", function()
        before_each(function()
            install()
            mapLoad()
        end)

        it("does not take the target from the tree that the swing trace finds", function()
            local stump = fakes.object({ class = "BP_ScavengableTree_102_C", name = "Stump", CurrentHealth = 0 })
            lookAt(stump) -- the 2.5 m reach of a stump catches the look-at in front of the tree
            swing(w.tree)
            runChecks()
            assert.are.equal(1, #w.serverHits)
            assert.are.equal(w.tree, w.serverHits[1].HitObjectHandle.ReferenceObject)
        end)

        it("leaves no recent prompt tree when it ends", function()
            local stump = fakes.object({
                class = "BP_ScavengableTree_102_C",
                name = "Stump",
                CurrentHealth = 0,
                K2_GetActorLocation = vecFn(120, 0, 0),
            })
            lookAt(w.tree)
            lookAway(w.tree)
            lookAt(stump)
            lookAway(stump)
            w.character.K2_GetActorLocation = vecFn(60, 0, 0)
            swing(nil)
            runChecks()
            assert.are.equal(1, #w.serverHits) -- the recent prompt is still the standing tree
            assert.are.equal(w.tree, w.serverHits[1].HitObjectHandle.ReferenceObject)
        end)
    end)

    describe("a swing", function()
        before_each(function()
            install()
            mapLoad()
        end)

        it("with no hit gets one assist each time, through the game's RPC with the tree actor", function()
            lookAt(w.tree)
            swing(w.tree)
            runChecks()
            assert.are.equal(1, #w.serverHits)
            assert.are.equal(w.tree, w.serverHits[1].HitObjectHandle.ReferenceObject)
            assert.is_false(w.weapon.DurabilityDecreased) -- ResetSwing before the assist
            swing(w.tree)
            runChecks()
            assert.are.equal(2, #w.serverHits)
        end)

        it("shows no screen message with verbose off", function()
            lookAt(w.tree)
            swing(w.tree)
            runChecks()
            assert.are.equal(0, #w.screen)
        end)

        it("that the game hits gets no assist", function()
            lookAt(w.tree)
            swing(w.tree)
            w.now = w.now + 0.5
            damaged(w.tree)
            runChecks()
            assert.are.equal(0, #w.serverHits)
        end)

        it("twice fast at the same tree gets one assist, for the newer swing", function()
            lookAt(w.tree)
            swing(w.tree)
            swing(w.tree)
            runChecks()
            assert.are.equal(1, #w.serverHits)
        end)

        it("at a rock with no prompt gets no check", function()
            swing(w.rock)
            assert.are.equal(0, #env.delays)
        end)

        it("that the game interrupts is checked at once, and only once", function()
            lookAt(w.tree)
            swing(w.tree)
            endAbility(true)
            env.hooks[INTERRUPTED](P(w.ability))
            assert.are.equal(1, #w.serverHits)
            runChecks()
            assert.are.equal(1, #w.serverHits)
        end)

        it("within 1.1 s of the last damage of the tree gets no assist", function()
            lookAt(w.tree)
            damaged(w.tree)
            w.now = w.now - 0.4 -- the swing below starts 0.1 s after the damage
            swing(w.tree)
            endAbility(false)
            runChecks()
            assert.are.equal(0, #w.serverHits)
        end)

        it("against the trunk, with no prompt and no trace actor, takes the recent prompt tree", function()
            lookAt(w.tree)
            lookAway(w.tree)
            w.character.K2_GetActorLocation = vecFn(60, 0, 0)
            swing(nil)
            runChecks()
            assert.are.equal(1, #w.serverHits)
        end)

        it("at a rock beside a recently seen tree is not a tree swing", function()
            lookAt(w.tree)
            lookAway(w.tree)
            w.character.K2_GetActorLocation = vecFn(60, 0, 0)
            swing(w.rock)
            assert.are.equal(0, #env.delays)
        end)

        it("leaves a newer swing at a rock alone when the older tree check runs", function()
            lookAt(w.tree)
            swing(w.tree)
            endAbility(false)
            lookAway(w.tree)
            w.now = w.now + 10 -- the recent prompt is old
            w.weapon.resets = 0
            swing(w.rock)
            runChecks()
            assert.are.equal(0, #w.serverHits)
            assert.are.equal(0, w.weapon.resets)
        end)

        it("at a falling tree gets no assist", function()
            w.tree.bScavenged = true -- the game sets it when the tree breaks
            lookAt(w.tree)
            swing(w.tree)
            runChecks()
            assert.are.equal(0, #w.serverHits)
        end)

        it("at a stump after a load (bScavenged false, health 0) that the player looks at gets no assist", function()
            w.tree.CurrentHealth = 0
            lookAt(w.tree)
            swing(w.tree)
            runChecks()
            assert.are.equal(0, #w.serverHits)
        end)

        it("at a removed stump gets no assist, also at an interrupt", function()
            w.tree.CurrentHealth = -1
            lookAt(w.tree)
            interrupt(w.tree)
            runChecks()
            assert.are.equal(0, #w.serverHits)
        end)

        it("at a stump that the swing trace finds is not restarted while the button is held", function()
            w.tree.CurrentHealth = 0
            key(true)
            interrupt(w.tree) -- no look-at: the swing trace finds the stump
            assert.are.equal(0, w.restarts)
        end)

        it("of the hit window toggle adds no hit", function()
            local toggle = env.hooks[WEAPON .. "SGK MeleeCollisionToggle"]
            swing(w.tree)
            toggle(P(w.weapon), P(false))
            toggle(P(w.weapon), P(true))
            toggle(P(w.weapon), P(false))
            endAbility(false)
            toggle(P(w.weapon), P(false))
            assert.are.equal(0, #w.serverHits)
        end)
    end)

    describe("a screen message", function()
        it("shows for each assist with verbose on", function()
            install({ verbose = true })
            mapLoad()
            lookAt(w.tree)
            swing(w.tree)
            runChecks()
            assert.are.equal(1, #w.screen)
            assert.are.equal(1, lines("swing 1 assisted tree=HTree"))
        end)
    end)

    describe("the trace", function()
        it("ignores the held weapon", function()
            install()
            mapLoad()
            lookAt(w.tree)
            swing(w.tree)
            runChecks()
            assert.are.equal(w.weapon, w.traceIgnores[1][1])
        end)

        it("falls back to an empty ignore list when the list throws, with one warning", function()
            install()
            w.throwOnIgnore = true
            mapLoad()
            lookAt(w.tree)
            swing(w.tree)
            runChecks()
            swing(w.tree)
            runChecks()
            assert.is_true(w.traceThrown)
            assert.are.equal(2, #w.serverHits)
            assert.are.equal(1, lines("WARN.*ignore list"))
            assert.are.equal(0, #w.traceIgnores[#w.traceIgnores])
        end)
    end)

    describe("the restart of a held attack", function()
        before_each(function()
            install()
            mapLoad()
            lookAt(w.tree)
        end)

        it("restarts an interrupted swing once while the button is held", function()
            key(true)
            interrupt(w.tree)
            assert.are.equal(1, w.restarts)
        end)

        it("does not restart after the release", function()
            key(true)
            key(false)
            interrupt(w.tree)
            assert.are.equal(0, w.restarts)
        end)

        it("does not restart a swing at a rock", function()
            lookAway(w.tree)
            key(true)
            w.now = w.now + 10 -- the recent prompt is old
            interrupt(w.rock)
            assert.are.equal(0, w.restarts)
        end)

        it("gives two restarts, then none, for three interrupts in a row with no hit", function()
            key(true)
            w.weapon["Server Hit Check"] = function() end
            for _ = 1, 3 do
                w.now = w.now + 2
                interrupt(w.tree)
            end
            assert.are.equal(2, w.restarts)
        end)
    end)

    describe("the verbose lines", function()
        it("log the swing end, the ability end, the tree damage, and the hit window", function()
            install({ verbose = true })
            mapLoad()
            lookAt(w.tree)
            swing(w.tree)
            env.hooks[WEAPON .. "SGK MeleeCollisionToggle"](P(w.weapon), P(true))
            damaged(w.tree)
            swing(w.tree)
            endAbility(false)
            env.hooks[WEAPON .. "SGK MeleeCollisionToggle"](P(w.weapon), P(false))
            assert.are.equal(1, lines("swing 1 end by=next swing prompt=HTree"))
            assert.are.equal(1, lines("swing 2 end by=ability end %(cancelled=false"))
            assert.are.equal(1, lines("tree HTree damaged by 34 %(swing 1"))
            assert.are.equal(1, lines("hit window open %(swing 1"))
            assert.are.equal(1, lines("hit window close %(no swing%)"))
        end)

        it("log why a swing got no assist when the trace misses the tree", function()
            install({ verbose = true })
            mapLoad()
            w.traceMiss = true
            lookAt(w.tree)
            swing(w.tree)
            runChecks()
            assert.are.equal(0, #w.serverHits)
            assert.are.equal(1, lines("swing 1 no assist: the line trace did not reach the tree"))
        end)
    end)

    describe("the arming", function()
        local function burst(n, props)
            for i = 1, n do
                local o = {}
                for k, v in pairs(props) do
                    o[k] = v
                end
                o.name = (props.class or "X") .. i
                env.spawn(fakes.object(o))
            end
        end

        local function hooked(prefix, fns)
            for _, fn in ipairs(fns) do
                if type(env.hooks[prefix .. fn]) ~= "function" then return false end
            end
            return true
        end

        local ATTACK = { "SurfaceTrace", "K2_OnEndAbility", "OnInterrupted" .. MONTAGE, "OnCancelled" .. MONTAGE }
        local WEAPON_FNS = { "SGK ClientPrimaryAction", "SGK MeleeCollisionToggle" }
        local TREE_FNS = { "AUTHORITY_HandleDamaged", "HandleLookAtStarted", "HandleLookAtEnded" }

        before_each(function()
            install({ verbose = true })
            env.holdGameThread = true
        end)

        it("queues no call for a burst of other abilities and other held items", function()
            burst(1000, { class = "GA_Other_C", isa = { "GameplayAbility_Base" } })
            burst(1000, { class = "BP_Torch_Holdable_C", isa = { "ItemHoldable" } })
            burst(1000, { class = "BP_ScavengeableRock_C" })
            assert.are.equal(0, #env.queued)
        end)

        it("queues one call for a burst of melee attacks, which arms the four attack hooks", function()
            burst(1000, { class = "GA_Attack_MeleePrimary_C" })
            assert.are.equal(1, #env.queued)
            env.runGameThread()
            assert.is_true(hooked(GA, ATTACK))
            assert.are.equal(4, lines("hit assist hook armed %(attack seen%) GA_Attack_MeleePrimary_C:"))
            assert.are.equal(0, #env.watchers[PATHS.GA_Attack_MeleePrimary_C])
        end)

        it("queues one call for a burst of axes, which arms the weapon hooks before the first key-down", function()
            burst(1000, { class = "BP_Iron_Axe_Refined_Holdable_C" })
            assert.are.equal(1, #env.queued)
            env.runGameThread()
            assert.is_true(hooked(WEAPON, WEAPON_FNS))
            assert.are.equal(2, lines("hit assist hook armed %(weapon seen%) BP_MasterMeleeWeapon_C:"))
            assert.are.equal(0, #env.watchers[PATHS.BP_MasterMeleeWeapon_C])
        end)

        it("queues one call for a burst of trees, which arms the three tree hooks", function()
            burst(1000, { class = "BP_ScavengableTree_104_C" })
            assert.are.equal(1, #env.queued)
            env.runGameThread()
            assert.is_true(hooked(TREE, TREE_FNS))
            assert.are.equal(3, lines("hit assist hook armed %(tree seen%) BP_ScavengeableTree_C:"))
            assert.are.equal(0, #env.watchers[PATHS.BP_ScavengeableTree_C])
        end)

        it("arms nothing at a map load", function()
            for _, fn in ipairs(env.loadMap.post) do
                fn()
            end
            env.runGameThread()
            assert.are.same({}, env.hooks)
        end)

        it("looks up no /Game/ object and walks no object list", function()
            burst(10, { class = "GA_Attack_MeleePrimary_C" })
            burst(10, { class = "BP_Iron_Axe_Refined_Holdable_C" })
            burst(10, { class = "BP_ScavengableTree_104_C" })
            env.runGameThread()
            env.holdGameThread = false
            lookAt(w.tree)
            swing(w.tree)
            runChecks()
            assert.are.equal(1, #w.serverHits)
            assert.are.same({ gameLookups = 0, findAllOf = 0 }, env.count)
        end)

        it("logs one warning for a hook that fails, and arms the others", function()
            env.failHook = ":SurfaceTrace"
            burst(1, { class = "GA_Attack_MeleePrimary_C" })
            env.runGameThread()
            assert.are.equal(1, lines("WARN hit assist hook failed: SurfaceTrace"))
            assert.is_function(env.hooks[GA .. "K2_OnEndAbility"])
        end)
    end)
end)
