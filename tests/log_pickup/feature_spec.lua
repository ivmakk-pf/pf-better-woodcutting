-- Glue specs of the log pickup: the break pickup, the show-again path, the nearby pickup, and the arming.
local fakes = require("fakes")
local PATHS = require("bw.paths")

local TREE = PATHS.BP_ScavengeableTree_C .. ":"
local LOG = PATHS.BP_TrunkPart_C

local P = fakes.param

local function V(x, y, z)
    return { X = x, Y = y, Z = z }
end

local function authority()
    return true
end

local realClock = os.clock
local env, w

local function newWorld()
    local world = { room = 2, logs = {} }
    world.character = fakes.object({ class = "BP_SGKMasterCharacter_C", name = "Char", HasAuthority = authority })
    world.at = V(500, 0, 0)
    world.character.K2_GetActorLocation = function()
        return world.at
    end
    local controller = fakes.object({ class = "PlayerController", Pawn = world.character })
    world.inventory = fakes.object({
        class = "BP_PlayerInventory_C",
        GetOwner = function()
            return controller
        end,
    })
    world.character.PlayerInventory = world.inventory
    local stump = fakes.object({
        class = "StaticMeshComponent",
        K2_GetComponentLocation = function()
            return V(0, 0, 0)
        end,
    })
    world.newTree = function(name)
        return env.spawn(fakes.object({
            class = "BP_ScavengableTree_102_C",
            name = name,
            Stump = stump,
            ["Damage Cause"] = world.character,
            HasAuthority = authority,
        }))
    end
    world.tree = world.newTree("Tree1")
    return world
end

-- A new log at x: owner is the tree that spawned it, nil for a log loaded from a save.
local function newLog(name, x, owner)
    local lg
    local mesh = fakes.object({
        class = "StaticMeshComponent",
        K2_GetComponentLocation = function()
            return V(x, 0, 0)
        end,
        K2_GetComponentRotation = function()
            return { Pitch = 0 }
        end,
        SetSimulatePhysics = function(_, v)
            lg.sim = v
        end,
        K2_SetWorldLocationAndRotation = function()
            lg.restored = true
        end,
    })
    lg = fakes.object({
        class = "BP_TrunkPart_C",
        name = name,
        ResourceMesh = mesh,
        ["Wood Loot Count"] = 6,
        bCollected = false,
        hidden = false,
        HasAuthority = authority,
        GetOwner = function()
            return owner
        end,
        SetActorEnableCollision = function(self, v)
            self.collision = v
        end,
        SetActorHiddenInGame = function(self, v)
            self.hidden = v
        end,
        BeginInteraction = function(self, params, character)
            assert.are.equal("Interact", params.ID)
            assert.are.equal(w.character, character)
            if w.room > 0 then
                w.room = w.room - 1
                self.bCollected = true
                self["Player Inventory"] = w.inventory
                env.hooks[LOG .. ":Collect Loot"](P(self))
            end
        end,
    })
    w.logs[#w.logs + 1] = lg
    env.spawn(lg)
    return lg
end

local function install(config)
    env = fakes.install()
    w = newWorld()
    for _, path in pairs(PATHS) do
        env.objects[path] = fakes.object({ class = "BlueprintGeneratedClass" })
    end
    package.loaded["bw.log_pickup.feature"] = nil
    local ctx = require("bw.core.context").new("BetterWoodcutting")
    ctx.config = config or { pickup_range_m = 15, nearby_range_m = 5, verbose = false }
    require("bw.log_pickup.feature").install(ctx)
end

-- A world load: the game makes the objects of the world, then the map-load callbacks run.
local function mapLoad()
    env.spawn(w.tree)
    for _, fn in ipairs(env.loadMap.post) do
        fn()
    end
end

local function breakTree(tree)
    env.hooks[TREE .. "Break Trunk Into Pieces"](P(tree))
end

local function lines(pattern)
    local n = 0
    for _, line in ipairs(env.printed) do
        if line:find(pattern) then n = n + 1 end
    end
    return n
end

describe("log pickup", function()
    after_each(function()
        os.clock = realClock
        fakes.restore()
        package.loaded["bw.log_pickup.feature"] = nil
    end)

    describe("a break", function()
        before_each(function()
            install()
            mapLoad()
        end)

        it("in range hides the logs, picks up those that fit, and shows the others again", function()
            breakTree(w.tree) -- an earlier contact with no logs
            local a, b, c = newLog("L1", 100, w.tree), newLog("L2", 200, w.tree), newLog("L3", 300, w.tree)
            breakTree(w.tree)
            assert.is_true(a.hidden and b.hidden and c.hidden)
            env.runDelays()
            assert.is_true(a.bCollected and b.bCollected)
            assert.is_false(c.bCollected)
            assert.is_false(c.hidden)
            assert.is_true(c.restored and c.collision and c.sim)
        end)

        it("out of range leaves the logs alone", function()
            w.at = V(5000, 0, 0)
            local lg = newLog("L7", 100, w.tree)
            breakTree(w.tree)
            assert.is_false(lg.hidden)
            assert.are.equal(0, #env.delays)
        end)

        it("shows a log again when its transform restore fails", function()
            w.room = 0
            local lg = newLog("L8", 100, w.tree)
            lg.ResourceMesh.K2_SetWorldLocationAndRotation = function()
                error("transform boom")
            end
            breakTree(w.tree)
            assert.is_true(lg.hidden)
            env.runDelays()
            assert.is_false(lg.hidden)
            assert.is_true(lg.collision and lg.sim)
            assert.are.equal(1, lines("WARN show transform: .*transform boom"))
        end)

        it("rolls back a log whose hide fails, and does not pick it up", function()
            local lg = newLog("L9", 100, w.tree)
            lg.SetActorHiddenInGame = function(self, v)
                if v then error("hide boom") end
                self.hidden = v
            end
            breakTree(w.tree)
            assert.is_true(lg.collision and lg.sim)
            assert.are.equal(1, #env.delays)
            env.runDelays()
            assert.is_false(lg.bCollected)
        end)

        it("of two trees at the same moment takes only the logs of its own tree", function()
            w.room = 5
            local tree2 = w.newTree("Tree2")
            local saved = newLog("S1", 100) -- a log loaded from a save: no owner
            local t2a, t1a = newLog("T2a", 100, tree2), newLog("T1a", 100, w.tree)
            breakTree(tree2)
            assert.is_true(t2a.hidden)
            assert.is_false(t1a.hidden or saved.hidden)
            breakTree(w.tree)
            assert.is_true(t1a.hidden)
            assert.is_false(saved.hidden)
            env.runDelays()
            assert.is_true(t2a.bCollected and t1a.bCollected)
            assert.is_false(saved.bCollected)
        end)

        it("does not read the owner of a log older than 0.5 s", function()
            local old = newLog("S2", 100)
            local reads = 0
            old.GetOwner = function()
                reads = reads + 1
                return nil
            end
            local later = realClock() + 1
            ---@diagnostic disable-next-line: duplicate-set-field
            os.clock = function()
                return later
            end
            breakTree(w.tree)
            breakTree(w.tree)
            assert.are.equal(0, reads)
        end)

        it("warns once and leaves the logs when no player cut the tree", function()
            w.tree["Damage Cause"] = nil
            local lg = newLog("L1", 100, w.tree)
            breakTree(w.tree)
            assert.is_false(lg.hidden)
            assert.are.equal(1, lines("WARN no player found for a felled tree"))
        end)
    end)

    describe("a log picked up by hand", function()
        before_each(function()
            install()
            mapLoad()
        end)

        it("also picks up the logs near it, not a far one", function()
            w.room = 3
            local picked = newLog("L3", 300)
            local l4, l5, l6 = newLog("L4", 350), newLog("L5", 600), newLog("L6", 2000)
            picked:BeginInteraction({ ID = "Interact" }, w.character)
            assert.is_true(picked.bCollected and l4.bCollected and l5.bCollected)
            assert.is_false(l6.bCollected)
        end)

        it("picks up nothing more with nearby_range_m 0", function()
            install({ pickup_range_m = 15, nearby_range_m = 0, verbose = false })
            mapLoad()
            w.room = 3
            local picked = newLog("L3", 300)
            local near = newLog("L4", 350)
            picked:BeginInteraction({ ID = "Interact" }, w.character)
            assert.is_false(near.bCollected)
        end)
    end)

    describe("a failure", function()
        before_each(function()
            install()
            mapLoad()
        end)

        it("of the player before the delayed pickup shows the logs again, with one warning", function()
            local lg = newLog("L1", 100, w.tree)
            breakTree(w.tree)
            w.character.destroyed = true
            env.runDelays()
            assert.is_false(lg.hidden or lg.bCollected)
            assert.are.equal(1, lines("WARN the player is gone; the log stays on the ground"))
        end)

        it("to read the player position leaves the logs, with one warning", function()
            w.character.K2_GetActorLocation = function()
                error("stale")
            end
            local lg = newLog("L1", 100, w.tree)
            breakTree(w.tree)
            assert.is_false(lg.hidden)
            assert.are.equal(1, lines("WARN cannot read the tree or player position"))
        end)

        it("of the break hook logs one warning", function()
            install()
            env.failHook = ":Break Trunk Into Pieces"
            mapLoad()
            assert.are.equal(1, lines("WARN tree hook failed: .*Break Trunk Into Pieces"))
        end)
    end)

    describe("the arming", function()
        it("arms the break hook and the nearby hook from its tree watcher in one queued call", function()
            install({ pickup_range_m = 15, nearby_range_m = 5, verbose = true })
            env.holdGameThread = true
            for _ = 1, 1000 do
                env.spawn(fakes.object({ class = "BP_ScavengableTree_102_C" }))
            end
            assert.are.equal(1, #env.queued)
            env.runGameThread()
            assert.is_function(env.hooks[TREE .. "Break Trunk Into Pieces"])
            assert.is_function(env.hooks[LOG .. ":Collect Loot"])
            assert.are.equal(0, #env.watchers[PATHS.BP_ScavengeableTree_C])
            assert.are.equal(1, lines("tree hook armed %(tree seen%)"))
        end)

        it("queues no call for a burst of rocks", function()
            install()
            env.holdGameThread = true
            for i = 1, 1000 do
                env.spawn(fakes.object({ class = "BP_ScavengeableRock_C", name = "Rock" .. i }))
            end
            assert.are.equal(0, #env.queued)
        end)

        it("watches the logs from the install, and arms nothing at a map load", function()
            install()
            assert.are.equal(1, #env.watchers[LOG])
            for _, fn in ipairs(env.loadMap.post) do
                fn()
            end
            assert.are.same({}, env.hooks)
        end)

        it("takes a burst of 4000 new logs", function()
            install()
            mapLoad()
            for i = 1, 4000 do
                env.spawn(fakes.object({ class = "BP_TrunkPart_C", name = "B" .. i }))
            end
            breakTree(w.tree)
            assert.are.equal(0, lines("WARN"))
        end)
    end)

    describe("the log list of the nearby pickup", function()
        it("holds a log that the game made before the first tree", function()
            install()
            w.room = 3
            local early = newLog("Early", 350)
            mapLoad()
            local picked = newLog("L3", 300)
            picked:BeginInteraction({ ID = "Interact" }, w.character)
            assert.is_true(early.bCollected)
        end)

        it("walks no object list", function()
            install()
            mapLoad()
            w.room = 3
            newLog("L4", 350)
            local picked = newLog("L3", 300)
            picked:BeginInteraction({ ID = "Interact" }, w.character)
            assert.are.equal(0, env.count.findAllOf)
        end)

        it("drops a log that is gone, and an address that now holds an object of another class", function()
            install({ pickup_range_m = 15, nearby_range_m = 5, verbose = true })
            mapLoad()
            w.room = 3
            local gone, other, near = newLog("Gone", 350), newLog("Other", 360), newLog("Near", 370)
            gone.destroyed = true
            other.class = "BP_Arrow_C"
            local picked = newLog("L3", 300)
            picked:BeginInteraction({ ID = "Interact" }, w.character)
            assert.is_true(near.bCollected)
            assert.is_false(other.bCollected)
            -- the picked log and the near one stay in the list; the two dropped entries are gone
            assert.are.equal(1, lines("nearby walk .* logs=2 "))
        end)
    end)

    describe("with every feature on", function()
        local OTHERS = { "bw.hit_assist.feature", "bw.hit_assist.assist", "bw.stump.feature" }

        after_each(function()
            package.loaded["UEHelpers"] = nil
            for _, name in ipairs(OTHERS) do
                package.loaded[name] = nil
            end
        end)

        it("looks up no /Game/ object and walks no object list over a session", function()
            install()
            package.loaded["UEHelpers"] = {
                GetKismetSystemLibrary = function()
                    return {
                        MakeSoftObjectPath = function(_, path)
                            return path
                        end,
                        Conv_SoftObjPathToSoftObjRef = function(_, path)
                            return path
                        end,
                        Conv_SoftObjectReferenceToObject = function()
                            return fakes.object()
                        end,
                        MakeSoftClassPath = function(_, path)
                            return path
                        end,
                        Conv_SoftClassPathToSoftClassRef = function(_, path)
                            return path
                        end,
                        Conv_SoftClassReferenceToClass = function()
                            return fakes.object()
                        end,
                    }
                end,
            }
            for _, name in ipairs(OTHERS) do
                package.loaded[name] = nil
            end
            local ctx = require("bw.core.context").new("BetterWoodcutting")
            ctx.config = { verbose = true, stump_hold_s = 2 }
            require("bw.hit_assist.feature").install(ctx)
            require("bw.stump.feature").install(ctx)
            mapLoad()
            env.runDelays()
            w.room = 5
            local a = newLog("L1", 100, w.tree)
            breakTree(w.tree)
            env.runDelays()
            newLog("L4", 350)
            local picked = newLog("L3", 300)
            picked:BeginInteraction({ ID = "Interact" }, w.character)
            assert.is_true(a.bCollected)
            assert.is_function(env.hooks[TREE .. "IsInteractionAllowed"])
            assert.are.equal(0, lines("WARN"))
            assert.are.same({ gameLookups = 0, findAllOf = 0 }, env.count)
        end)
    end)
end)
