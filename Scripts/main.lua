-- BetterWoodcutting: puts the wood of a felled tree into the inventory of the player who cut it (log_pickup),
-- gives an axe swing at a tree that does not hit one hit through the game's own RPC (hit_assist), and removes a
-- stump at a hold of the interact key with an axe in hand, for the wood of one log (stump_removal).
local MOD = "BetterWoodcutting"
local VERSION = "1.1.0"

local SCHEMA = require("bw.core.schema")

-- Features: { config switch, module }. A failed install turns off only its feature.
local FEATURES = {
    { switch = "log_pickup", module = "bw.log_pickup.feature" },
    { switch = "hit_assist", module = "bw.hit_assist.feature" },
    { switch = "stump_removal", module = "bw.stump.feature" },
}

local ctx = require("bw.core.context").new(MOD)
ctx.config = require("bw.core.config_file").load(SCHEMA, ctx.log)

local states = {}
for _, feature in ipairs(FEATURES) do
    if ctx.config[feature.switch] then
        local ok, err = pcall(function()
            require(feature.module).install(ctx)
        end)
        states[#states + 1] = feature.switch .. (ok and " on" or " FAILED")
        if not ok then ctx.warnOnce(feature.module, feature.module .. " not installed: " .. tostring(err)) end
    else
        states[#states + 1] = feature.switch .. " off"
    end
end

ctx.log("v" .. VERSION .. " loaded (" .. table.concat(states, ", ") .. ")")
