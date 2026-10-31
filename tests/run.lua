-- Test runner for the game-free logic. Run from the mod folder:
--   mise exec -- lua tests/run.lua
-- Plain Lua 5.4 cannot list a folder, so the spec files are listed here.
local SPECS = {
    "config_logic_spec",
    "config_file_spec",
    "log_pickup_logic_spec",
    "hit_assist_logic_spec",
}

local here = (arg and arg[0] or ""):match("^(.*)[/\\]") or "."
package.path = here .. "/../Scripts/?.lua;" .. here .. "/?.lua;" .. package.path

local passed, failed = 0, 0
local failures = {}
local prefix = {}

function describe(name, body)
    prefix[#prefix + 1] = name
    body()
    prefix[#prefix] = nil
end

function it(name, body)
    local full = table.concat(prefix, " ") .. " " .. name
    local ok, err = pcall(body)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        failures[#failures + 1] = full .. "\n    " .. tostring(err)
    end
end

-- assert_eq(actual, expected[, message]) with both values in the error.
function assert_eq(actual, expected, message)
    if actual ~= expected then
        error(
            (message and (message .. ": ") or "") .. "expected " .. tostring(expected) .. ", got " .. tostring(actual),
            2
        )
    end
end

for _, spec in ipairs(SPECS) do
    local ok, err = pcall(dofile, here .. "/" .. spec .. ".lua")
    if not ok then
        failed = failed + 1
        failures[#failures + 1] = spec .. " (load)\n    " .. tostring(err)
    end
end

for _, line in ipairs(failures) do
    print("FAIL " .. line)
end
print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
