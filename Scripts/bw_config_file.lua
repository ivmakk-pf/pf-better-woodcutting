-- Loads config.lua from the mod folder, and writes it with the defaults when it is missing.
local config_logic = require("bw_config_logic")

local M = {}

local function literal(value)
    if type(value) == "string" then return string.format("%q", value) end
    return tostring(value)
end

-- The text of a new config.lua: one commented line for each schema entry.
---@param schema ConfigEntry[]
---@return string
function M.text(schema)
    local lines = { "-- Settings of the mod. A change applies at the next game start.", "return {" }
    for _, entry in ipairs(schema) do
        local comment = entry.comment
        if entry.min and entry.max then
            comment = comment
                .. string.format(
                    " (%s to %s, default %s)",
                    literal(entry.min),
                    literal(entry.max),
                    literal(entry.default)
                )
        end
        lines[#lines + 1] = "    -- " .. comment
        lines[#lines + 1] = "    " .. entry.key .. " = " .. literal(entry.default) .. ","
    end
    lines[#lines + 1] = "}"
    return table.concat(lines, "\n") .. "\n"
end

-- <...>\Mods\<Name>\ from the path of this file (<...>\Mods\<Name>\Scripts\bw_config_file.lua).
local function modFolder()
    local source = debug.getinfo(1, "S").source:gsub("^@", "")
    return source:match("^(.*[/\\])Scripts[/\\][^/\\]+$")
end

-- Returns the validated settings. Logs each problem through log; never overwrites a config file.
---@param schema ConfigEntry[]
---@param log fun(message: string)
---@return table<string, any>
function M.load(schema, log)
    local warn = function(key, message)
        log("WARN config " .. key .. ": " .. message)
    end
    local folder = modFolder()
    if not folder then
        log("WARN config: mod folder not found, using the defaults")
        return config_logic.validate({}, schema, warn)
    end
    local path = folder .. "config.lua"
    local existing = io.open(path, "r")
    if not existing then
        local file, err = io.open(path, "w")
        if file then
            file:write(M.text(schema))
            file:close()
            log("wrote " .. path)
        else
            log("WARN config: cannot write " .. path .. ": " .. tostring(err))
        end
        return config_logic.validate({}, schema, warn)
    end
    existing:close()
    local ok, raw = pcall(dofile, path)
    if not ok or type(raw) ~= "table" then
        log("WARN config: cannot read " .. path .. ", using the defaults: " .. tostring(raw))
        raw = {}
    end
    return config_logic.validate(raw, schema, warn)
end

return M
