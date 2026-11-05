-- Fake UE4SS globals and fake UObjects for the specs, on luassert spies. A spec calls
-- fakes.install() in before_each and fakes.restore() in after_each, and loads the module under
-- test fresh (package.loaded[name] = nil), so each test starts with new state.
-- The behavior copies what the game runs showed: a Blueprint hook gets only its first callback,
-- and a NotifyOnNewObject callback gets an object that is not set up yet.
local spy = require("luassert.spy")

local M = {}

local NAMES = {
    "RegisterHook",
    "NotifyOnNewObject",
    "ExecuteInGameThread",
    "LoopAsync",
    "StaticFindObject",
    "FindFirstOf",
    "RegisterLoadMapPreHook",
    "RegisterLoadMapPostHook",
    "FName",
    "FText",
    "print",
    "StaticConstructObject",
    "FindAllOf",
    "ExecuteWithDelay",
    "LoadAsset",
    "RegisterKeyBind",
    "Key",
}

-- The UMG classes that the HUD build makes, by path.
M.UMG = {
    UserWidget = "/Script/UMG.UserWidget",
    WidgetTree = "/Script/UMG.WidgetTree",
    CanvasPanel = "/Script/UMG.CanvasPanel",
    TextBlock = "/Script/UMG.TextBlock",
}
local saved = nil
local nextAddress = 0x1000

local NATIVE = "/Script/Permafrost"
local TREES = "/Game/Permafrost/Blueprints/Interactions/Scavengable"
local HOLDABLE = "/Game/Permafrost/Blueprints/Items/HoldableItems"
local SGK = "/Game/SurvivalGameKitV2/Blueprints/Items/HoldableItems"

-- The classes of the fake objects: the package of each class and its parent, from the header dump
-- and game/registry/. UE4SS matches a watcher on both names (LuaMod.cpp), so a wrong package in
-- bw/paths.lua fails a spec.
M.CLASSES = {
    GameplayAbility_Base = { package = NATIVE },
    ItemHoldable = { package = NATIVE },
    Scavengeable = { package = NATIVE },
    InteractionBase = { package = NATIVE },
    GeneralHUDWidget = { package = NATIVE },
    PermaCharacter = { package = NATIVE },
    BP_SGKMasterCharacter_C = {
        package = "/Game/SurvivalGameKitV2/Blueprints/Characters/BP_SGKMasterCharacter",
        parent = "PermaCharacter",
    },
    GA_Attack_MeleePrimary_C = {
        package = "/Game/Permafrost/Blueprints/GAS/GameplayAbilities/Items/GA_Attack_MeleePrimary",
        parent = "GameplayAbility_Base",
    },
    BP_MasterHoldable_C = { package = SGK .. "/BP_MasterHoldable", parent = "ItemHoldable" },
    BP_MasterWeapon_C = { package = SGK .. "/BP_MasterWeapon", parent = "BP_MasterHoldable_C" },
    BP_MasterMeleeWeapon_C = { package = SGK .. "/BP_MasterMeleeWeapon", parent = "BP_MasterWeapon_C" },
    BP_MasterAxe_C = { package = HOLDABLE .. "/Abstract/BP_MasterAxe", parent = "BP_MasterMeleeWeapon_C" },
    BP_Iron_Axe_Refined_Holdable_C = {
        package = HOLDABLE .. "/Iron/BP_Iron_Axe_Refined_Holdable",
        parent = "BP_MasterAxe_C",
    },
    BP_Iron_Knife_Holdable_C = {
        package = HOLDABLE .. "/Iron/BP_Iron_Knife_Holdable",
        parent = "BP_MasterMeleeWeapon_C",
    },
    BP_ScavengeableTree_C = { package = TREES .. "/BP_ScavengeableTree", parent = "Scavengeable" },
    BP_ScavengeableRock_C = { package = TREES .. "/BP_ScavengeableRock", parent = "Scavengeable" },
    BP_InteractionBase_C = {
        package = "/Game/Permafrost/Blueprints/Interactions/Core/BP_InteractionBase",
        parent = "InteractionBase",
    },
    BP_TrunkPart_C = {
        package = "/Game/Permafrost/Blueprints/Interactions/LooseResource/Wood/BP_TrunkPart",
        parent = "BP_InteractionBase_C",
    },
    UW_HUD_C = { package = "/Game/Permafrost/UI/HUD/UW_HUD", parent = "GeneralHUDWidget" },
}

-- The class entry of a name; a numbered tree class (BP_ScavengableTree_102_C) is a child of the tree.
---@param name string
---@return { package: string, parent: string? }?
function M.classInfo(name)
    local known = M.CLASSES[name]
    if known then return known end
    local base = name:match("^(BP_ScavengableTree_%d+)_C$")
    if base then return { package = TREES .. "/Trees/" .. base, parent = "BP_ScavengeableTree_C" } end
    return nil
end

-- The class chain of a class name: the class, then each parent, from M.CLASSES.
---@param name string
---@return string[]
function M.chainOf(name)
    local chain = {}
    local info = { parent = name } ---@type { package: string?, parent: string? }?
    while info and info.parent do
        chain[#chain + 1] = info.parent
        info = M.classInfo(info.parent)
    end
    return chain
end

---@class BwFakeEnv
---@field hooks table<string, function> the callback of each registered hook path
---@field posts table<string, function?> the second callback of each registered hook path
---@field watchers table<string, function[]> the callbacks of each watched class path, in order
---@field notify fun(path: string, obj: any) calls each watcher of path with obj, and removes a watcher that returns true
---@field holdGameThread boolean? while true, ExecuteInGameThread keeps each call in `queued` until runGameThread()
---@field queued function[] the held game-thread calls
---@field runGameThread fun() runs the held game-thread calls in order (a call that queues another runs it too)
---@field spawn fun(obj: any): any dispatches a new object to the watchers of its class chain, as UE4SS does
---@field count { gameLookups: integer, findAllOf: integer } each StaticFindObject of a /Game/ path, each FindAllOf
---@field loops function[] the active LoopAsync callbacks
---@field printed string[] each print line
---@field objects table<string, any> what StaticFindObject finds, by path
---@field firstOf table<string, any> what FindFirstOf finds, by class name
---@field loadMap { pre: function[], post: function[] } the map-load callbacks
---@field failHook string? RegisterHook throws for a path with this suffix (a test can set it later)
---@field failWatch boolean? NotifyOnNewObject throws while it is true
---@field spy table<string, any> the fake of each global, for assert.spy(env.spy.RegisterHook)
---@field tick fun() runs each active loop once
---@field constructed any[] each object of StaticConstructObject, in order
---@field allOf table<string, any[]> what FindAllOf finds, by class name
---@field failConstruct boolean? StaticConstructObject throws while it is true
---@field delays { ms: integer, fn: function }[] the waiting ExecuteWithDelay callbacks
---@field runDelays fun() runs the waiting delays once (a delay that a delay adds waits for the next run)
---@field assets table<string, any> what LoadAsset loads, by path: a loaded asset is in objects after it
---@field keys table<string, function> the callback of each key bind, by key name

---@param opts { failHook: string? }? failHook: RegisterHook throws for a path with this suffix
---@return BwFakeEnv
function M.install(opts)
    opts = opts or {}
    saved = {}
    for _, name in ipairs(NAMES) do
        saved[name] = rawget(_G, name)
    end
    local env = {
        hooks = {},
        posts = {},
        watchers = {},
        loops = {},
        printed = {},
        objects = {},
        firstOf = {},
        loadMap = { pre = {}, post = {} },
        constructed = {},
        allOf = {},
        delays = {},
        assets = {},
        keys = {},
    }
    for name, path in pairs(M.UMG) do
        env.objects[path] = M.object({ class = "Class", name = name })
    end
    env.failHook = opts.failHook
    local ids = 0

    -- The globals go in through a loop with a variable key, so LuaLS keeps the UE4SS types of
    -- these names (a literal `_G.X = spy` or `rawset(_G, "X", spy)` would change them).
    ---@type table<string, any>
    local globals = {
        RegisterHook = spy.new(function(path, fn, post)
            if env.failHook and path:sub(-#env.failHook) == env.failHook then
                error("No UFunction with the specified name was found: " .. path)
            end
            env.hooks[path] = fn
            env.posts[path] = post
            ids = ids + 2
            return ids - 1, ids
        end),
        NotifyOnNewObject = spy.new(function(class, fn)
            if env.failWatch then error("watch failed: " .. class) end
            env.watchers[class] = env.watchers[class] or {}
            table.insert(env.watchers[class], fn)
        end),
        ExecuteInGameThread = spy.new(function(fn)
            if env.holdGameThread then
                env.queued[#env.queued + 1] = fn
            else
                fn()
            end
        end),
        LoopAsync = spy.new(function(_, fn)
            env.loops[#env.loops + 1] = fn
        end),
        StaticFindObject = spy.new(function(path)
            if path:sub(1, 6) == "/Game/" then env.count.gameLookups = env.count.gameLookups + 1 end
            return env.objects[path]
        end),
        FindFirstOf = spy.new(function(class)
            return env.firstOf[class]
        end),
        -- Plain functions, not spies: a mod checks `type(RegisterLoadMapPreHook) == "function"`,
        -- and a spy is a callable table.
        RegisterLoadMapPreHook = function(fn)
            env.loadMap.pre[#env.loadMap.pre + 1] = fn
        end,
        RegisterLoadMapPostHook = function(fn)
            env.loadMap.post[#env.loadMap.post + 1] = fn
        end,
        FName = function(s)
            return s
        end,
        FText = function(s)
            return s
        end,
        print = spy.new(function(s)
            env.printed[#env.printed + 1] = s
        end),
        StaticConstructObject = spy.new(function(class, outer)
            if env.failConstruct then error("construct failed: " .. tostring(class and class.name)) end
            local o = M.widget(class.name)
            o.outer = outer
            env.constructed[#env.constructed + 1] = o
            return o
        end),
        FindAllOf = spy.new(function(class)
            env.count.findAllOf = env.count.findAllOf + 1
            return env.allOf[class]
        end),
        ExecuteWithDelay = spy.new(function(ms, fn)
            env.delays[#env.delays + 1] = { ms = ms, fn = fn }
        end),
        LoadAsset = spy.new(function(path)
            local asset = env.assets[path]
            env.objects[path] = asset
            return asset
        end),
        RegisterKeyBind = spy.new(function(key, modifiers, fn)
            env.keys[key] = fn or modifiers
        end),
        -- Key.V is "V": a key code is its name in the fakes.
        Key = setmetatable({}, {
            __index = function(_, name)
                return name
            end,
        }),
    }
    for _, name in ipairs(NAMES) do
        _G[name] = globals[name]
    end
    env.spy = globals

    env.queued = {}
    env.count = { gameLookups = 0, findAllOf = 0 }

    -- A new object, as UE4SS dispatches it: each watcher whose class name and package name match
    -- one class of the chain of obj gets one call, and a watcher that returns true is removed.
    function env.spawn(obj)
        local names = obj.isa and { obj.class, table.unpack(obj.isa) } or M.chainOf(obj.class)
        local chain = {}
        for _, name in ipairs(names) do
            local info = M.classInfo(name)
            if info then chain[info.package .. "." .. name] = true end
        end
        local paths = {}
        for path in pairs(env.watchers) do
            if chain[path] then paths[#paths + 1] = path end
        end
        for _, path in ipairs(paths) do
            env.notify(path, obj)
        end
        return obj
    end

    function env.runGameThread()
        local i = 1
        while env.queued[i] do
            env.queued[i]()
            i = i + 1
        end
        env.queued = {}
    end

    -- As UE4SS does, a watcher whose callback returns true is removed.
    function env.notify(path, obj)
        local kept = {}
        for _, fn in ipairs(env.watchers[path] or {}) do
            if fn(obj) ~= true then kept[#kept + 1] = fn end
        end
        env.watchers[path] = kept
    end

    function env.runDelays()
        local waiting = env.delays
        env.delays = {}
        for _, d in ipairs(waiting) do
            d.fn()
        end
    end

    function env.tick()
        local active = {}
        for _, fn in ipairs(env.loops) do
            if fn() ~= true then active[#active + 1] = fn end
        end
        env.loops = active
    end
    return env
end

function M.restore()
    if not saved then return end
    for _, name in ipairs(NAMES) do
        _G[name] = saved[name]
    end
    saved = nil
end

local function fname(s)
    return {
        ToString = function()
            return s
        end,
    }
end

-- A fake UObject: IsValid (false after `destroyed = true`), GetAddress, GetClass():GetFName(),
-- GetClass():GetCDO() (the `cdo` field), IsA (true for `class` and each name in `isa`), and
-- GetFName() of `class` and `name`. Other fields of props become its properties and methods.
-- An IsA class argument is a fake object whose `name` is the class name.
---@param props table?
---@return any
function M.object(props)
    local o = props or {}
    nextAddress = nextAddress + 0x10
    local address = nextAddress
    o.IsValid = function(self)
        return not self.destroyed
    end
    o.GetAddress = function()
        return address
    end
    -- The class chain: the class, then each name in `isa`, in order (else the parents of M.CLASSES),
    -- then an invalid object.
    o.GetClass = function(self)
        local names = { self.class }
        if self.isa then
            for _, name in ipairs(self.isa) do
                names[#names + 1] = name
            end
        elseif self.class then
            names = M.chainOf(self.class)
        end
        local function class(i)
            if not names[i] then
                return {
                    IsValid = function()
                        return false
                    end,
                }
            end
            return {
                IsValid = function()
                    return true
                end,
                GetFName = function()
                    return fname(names[i])
                end,
                GetCDO = function()
                    return self.cdo
                end,
                GetSuperStruct = function()
                    return class(i + 1)
                end,
            }
        end
        return class(1)
    end
    o.IsA = function(self, class)
        if class.name == self.class then return true end
        for _, name in ipairs(self.isa or {}) do
            if class.name == name then return true end
        end
        return false
    end
    o.GetFName = function(self)
        return fname(self.name)
    end
    return o
end

-- A fake widget of a class: a fake object whose methods that props does not set record their
-- calls. `calls` lists each call as { name, args... }; `last[name]` holds the args of the last call
-- of name. AddChildToCanvas returns a new fake canvas slot, kept in `slots`.
---@param class string
---@param props table?
---@return any
function M.widget(class, props)
    local o = M.object(props or {})
    o.class = o.class or class
    o.calls, o.last, o.slots = {}, {}, {}
    if class == "CanvasPanel" and not o.AddChildToCanvas then
        o.AddChildToCanvas = function(self, child)
            local slot = M.widget("CanvasPanelSlot")
            slot.content = child
            self.slots[#self.slots + 1] = slot
            return slot
        end
    end
    return setmetatable(o, {
        __index = function(_, name)
            if type(name) ~= "string" or not name:match("^%u") then return nil end
            return function(self, ...)
                self.calls[#self.calls + 1] = { name, ... }
                self.last[name] = { ... }
            end
        end,
    })
end

-- The call names of a fake widget, in order.
---@param widget any
---@return string[]
function M.callNames(widget)
    local names = {}
    for _, call in ipairs(widget.calls) do
        names[#names + 1] = call[1]
    end
    return names
end

-- A fake RemoteUnrealParam of a hook callback.
---@param value any
---@return any
function M.param(value)
    local p = { value = value }
    function p:get()
        return self.value
    end
    function p:set(v)
        self.value = v
    end
    return p
end

return M
