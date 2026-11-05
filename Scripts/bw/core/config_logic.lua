-- Validates the settings of config.lua against the schema. Game-free: no UE4SS global.
local M = {}

---@class ConfigEntry
---@field key string
---@field default boolean|number|string the type of the default is the type of the setting
---@field min? number
---@field max? number
---@field comment string written above the key in a new config.lua

-- Returns a table with one value for each schema key.
---@param raw table<string, any> the table that config.lua returns
---@param schema ConfigEntry[]
---@param warn fun(key: string, message: string)
---@return table<string, any>
function M.validate(raw, schema, warn)
    local cfg = {}
    for _, entry in ipairs(schema) do
        local key, value = entry.key, raw[entry.key]
        if value == nil then
            cfg[key] = entry.default
        elseif type(value) ~= type(entry.default) then
            warn(
                key,
                "wrong type "
                    .. type(value)
                    .. ", expected "
                    .. type(entry.default)
                    .. "; using "
                    .. tostring(entry.default)
            )
            cfg[key] = entry.default
        elseif value ~= value then
            warn(key, "not a number; using " .. tostring(entry.default))
            cfg[key] = entry.default
        elseif entry.min and value < entry.min then
            warn(key, tostring(value) .. " is below " .. entry.min .. "; using " .. entry.min)
            cfg[key] = entry.min
        elseif entry.max and value > entry.max then
            warn(key, tostring(value) .. " is above " .. entry.max .. "; using " .. entry.max)
            cfg[key] = entry.max
        else
            cfg[key] = value
        end
    end
    return cfg
end

return M
