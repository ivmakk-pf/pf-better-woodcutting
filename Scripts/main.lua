-- BetterWoodcutting: puts the wood of a felled tree into the inventory of the player who cut it (log_pickup),
-- and gives an axe swing at a tree that does not hit one hit through the game's own RPC (hit_assist).
local MOD = "BetterWoodcutting"
local VERSION = "1.0.0"

---@class FeatureContext
---@field config table<string, any> the validated settings of config.lua
---@field log fun(message: string)
---@field warnOnce fun(key: string, message: string)
---@field trace fun(message: string) logs only when `verbose` is on
---@field try fun(fn: fun(): any): any the result of fn, nil when it errors (a stale object, a changed game)
---@field valid fun(obj: any): boolean
---@field guard fun(key: string, fn: function): fun(...) fn in a pcall that logs each distinct error once
---@field classPath fun(short: string): string? the full path of a loaded class, nil when it is not in memory

-- The one source of the config keys, defaults, ranges, and comments.
---@type ConfigEntry[]
local SCHEMA = {
    {
        key = "log_pickup",
        default = true,
        comment = "Pick up the logs of a felled tree for the player who cut it.",
    },
    {
        key = "pickup_range_m",
        default = 15,
        min = 1,
        max = 100,
        comment = "The player must be this close to the tree stump when the trunk breaks, in metres.",
    },
    {
        key = "nearby_range_m",
        default = 5,
        min = 0,
        max = 20,
        comment = "A log picked up by hand also picks up the other logs this close to it, in metres. 0 turns this off.",
    },
    {
        key = "hit_assist",
        default = true,
        comment = "An axe swing at a tree that does not hit gets one hit, also at the prompt edge or against the trunk; a held attack goes on after the game interrupts it.",
    },
    { key = "verbose", default = false, comment = "Extra log lines in UE4SS.log. Keep off in normal play." },
}

local function log(message)
    print("[" .. MOD .. "] " .. message .. "\n")
end

local warned = {}
local function warnOnce(key, message)
    if warned[key] then return end
    warned[key] = true
    log("WARN " .. message)
end

local config = require("bw_config_file").load(SCHEMA, log)

-- Not named "debug": that would hide the Lua debug library.
local function trace(message)
    if config.verbose then log(message) end
end

---@param fn fun(): any
---@return any
local function try(fn)
    local ok, value = pcall(fn)
    if ok then return value end
    return nil
end

local function valid(obj)
    return obj ~= nil and try(function()
        return obj:IsValid()
    end) == true
end

local function guard(key, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then warnOnce(key, key .. ": " .. tostring(err)) end
    end
end

local function classPath(short)
    for _, kind in ipairs({ "BlueprintGeneratedClass", false }) do
        local cls = try(function()
            return FindObject(kind or nil, short)
        end)
        if valid(cls) then
            local full = try(function()
                return cls:GetFullName()
            end) or ""
            local path = full:match("^%S+ (/.+)$")
            if path and path:sub(-#short) == short then return path end
        end
    end
    return nil
end

-- Features: { config switch, module }. A failed install turns off only its feature.
local FEATURES = {
    { switch = "log_pickup", module = "bw_log_pickup" },
    { switch = "hit_assist", module = "bw_hit_assist" },
}

---@type FeatureContext
local context = {
    config = config,
    log = log,
    warnOnce = warnOnce,
    trace = trace,
    try = try,
    valid = valid,
    guard = guard,
    classPath = classPath,
}
local states = {}
for _, feature in ipairs(FEATURES) do
    if config[feature.switch] then
        local ok, err = pcall(function()
            require(feature.module).install(context)
        end)
        states[#states + 1] = feature.switch .. (ok and " on" or " FAILED")
        if not ok then warnOnce(feature.module, feature.module .. " not installed: " .. tostring(err)) end
    else
        states[#states + 1] = feature.switch .. " off"
    end
end

log("v" .. VERSION .. " loaded (" .. table.concat(states, ", ") .. ")")
