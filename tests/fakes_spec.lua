-- The fakes copy the UE4SS dispatch of new objects (LuaMod.cpp): a spec that relies on a wrong
-- copy would pass while the game fails.
local fakes = require("fakes")
local PATHS = require("bw.paths")

-- The UE4SS type of the callback has no parameter and no return value; the dispatch gives both.
local function notifyOn(path, fn)
    local register = NotifyOnNewObject ---@type any
    register(path, fn)
end

describe("fakes.spawn", function()
    local env

    before_each(function()
        env = fakes.install()
    end)

    after_each(function()
        fakes.restore()
    end)

    local function watch(path)
        local seen = {}
        notifyOn(path, function(obj)
            seen[#seen + 1] = obj
        end)
        return seen
    end

    it("calls a watcher on the class and a watcher on a parent class", function()
        local own = watch(PATHS.BP_ScavengeableTree_C)
        local parent = watch("/Script/Permafrost.Scavengeable")
        local tree = env.spawn(fakes.object({ class = "BP_ScavengableTree_102_C" }))
        assert.are.same({ tree }, own)
        assert.are.same({ tree }, parent)
    end)

    it("gives no call to a watcher with the right class name and a wrong package", function()
        local wrong = watch("/Game/Permafrost/Blueprints/Wrong/BP_ScavengeableTree.BP_ScavengeableTree_C")
        env.spawn(fakes.object({ class = "BP_ScavengableTree_102_C" }))
        assert.are.equal(0, #wrong)
    end)

    it("gives no call to a watcher of another class", function()
        local logs = watch(PATHS.BP_TrunkPart_C)
        env.spawn(fakes.object({ class = "BP_ScavengeableRock_C" }))
        assert.are.equal(0, #logs)
    end)

    it("removes a watcher whose callback returns true", function()
        local calls = 0
        notifyOn(PATHS.BP_MasterMeleeWeapon_C, function()
            calls = calls + 1
            return true
        end)
        env.spawn(fakes.object({ class = "BP_Iron_Axe_Refined_Holdable_C" }))
        env.spawn(fakes.object({ class = "BP_Iron_Axe_Refined_Holdable_C" }))
        assert.are.equal(1, calls)
    end)

    it("knows the package of each class path of the mod", function()
        for short, path in pairs(PATHS) do
            local info = fakes.classInfo(short)
            assert.is_table(info)
            assert.are.equal(path, info and info.package .. "." .. short)
        end
    end)

    it("counts each lookup of a /Game/ path and each FindAllOf", function()
        StaticFindObject("/Script/Permafrost.Default__PermaFunctionLibrary")
        StaticFindObject(PATHS.BP_TrunkPart_C)
        FindAllOf("BP_TrunkPart_C")
        assert.are.same({ gameLookups = 1, findAllOf = 1 }, env.count)
    end)
end)
