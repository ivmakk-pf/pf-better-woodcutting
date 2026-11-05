-- Loads config.lua from the mod folder, and writes it with the defaults when it is missing.
local config_logic = require("bw.core.config_logic")

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

-- <...>\Mods\<Name>\ from the path of a file in <...>\Mods\<Name>\Scripts\ or in a subfolder of it.
-- The greedy .* takes the last Scripts folder of the path.
---@param source string a file path, or a chunk name that starts with "@"
---@return string?
function M.folderOf(source)
    return (source:gsub("^@", "")):match("^(.*[/\\])Scripts[/\\].+$")
end

-- The mod folder from the path of this file. UE4SS loads it by its full path.
---@return string?
function M.modFolder()
    return M.folderOf(debug.getinfo(1, "S").source)
end

-- Returns the validated settings. Logs each problem through log; never overwrites a config file.
---@param schema ConfigEntry[]
---@param log fun(message: string)
---@param folder string? the mod folder with a trailing slash (the specs give a temp folder)
---@return table<string, any>
function M.load(schema, log, folder)
    local warn = function(key, message)
        log("WARN config " .. key .. ": " .. message)
    end
    folder = folder or M.modFolder()
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
