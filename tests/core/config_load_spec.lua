-- config_file.load with a temp mod folder, so no test writes into the mod folder.
local lfs = require("lfs")
local config_file = require("bw.core.config_file")

local SCHEMA = {
    { key = "log_pickup", default = true, comment = "switch" },
    { key = "range_m", default = 15, min = 1, max = 100, comment = "range" },
}

local function write(path, text)
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
end

local function read(path)
    local f = assert(io.open(path, "rb"))
    local text = f:read("a")
    f:close()
    return text
end

describe("config_file.folderOf", function()
    it("is the mod folder above Scripts, with a trailing slash", function()
        assert.are.equal(
            "C:\\Game\\Mods\\BetterWoodcutting\\",
            config_file.folderOf("@C:\\Game\\Mods\\BetterWoodcutting\\Scripts\\bw_config_file.lua")
        )
        assert.are.equal("/g/Mods/X/", config_file.folderOf("/g/Mods/X/Scripts/bw_config_file.lua"))
    end)

    it("is the mod folder for a file in a subfolder of Scripts", function()
        assert.are.equal(
            "C:\\Game\\Mods\\BetterWoodcutting\\",
            config_file.folderOf("@C:\\Game\\Mods\\BetterWoodcutting\\Scripts\\bw\\core\\config_file.lua")
        )
    end)

    it("takes the last Scripts folder of the path", function()
        assert.are.equal(
            "/a/Scripts/Mods/X/",
            config_file.folderOf("/a/Scripts/Mods/X/Scripts/bw/core/config_file.lua")
        )
    end)

    it("is nil for a file that is not in a Scripts folder", function()
        assert.is_nil(config_file.folderOf("@C:\\Game\\Mods\\X\\bw_config_file.lua"))
        assert.is_nil(config_file.folderOf("Scripts/bw_config_file.lua"))
    end)

    it("is what modFolder reads from the path of the loaded file", function()
        assert.are.equal(
            config_file.folderOf(debug.getinfo(config_file.modFolder, "S").source),
            config_file.modFolder()
        )
    end)
end)

describe("config_file.load", function()
    local folder, logged

    local function log(message)
        logged[#logged + 1] = message
    end

    before_each(function()
        folder = os.tmpname():gsub("[/\\][^/\\]*$", "") .. "/bw_spec_" .. os.time() .. math.random(1e6) .. "/"
        assert(lfs.mkdir(folder))
        logged = {}
    end)

    after_each(function()
        os.remove(folder .. "config.lua")
        lfs.rmdir(folder)
    end)

    it("writes config.lua with the defaults at the first start, and gives the defaults", function()
        local cfg = config_file.load(SCHEMA, log, folder)
        assert.are.same({ log_pickup = true, range_m = 15 }, cfg)
        assert.are.same({ "wrote " .. folder .. "config.lua" }, logged)
        assert.are.same({ log_pickup = true, range_m = 15 }, assert(loadfile(folder .. "config.lua"))())
    end)

    it("reads an existing config.lua and never overwrites it", function()
        write(folder .. "config.lua", "return { log_pickup = false }\n")
        local cfg = config_file.load(SCHEMA, log, folder)
        assert.are.same({ log_pickup = false, range_m = 15 }, cfg)
        assert.are.same({}, logged)
        assert.are.equal("return { log_pickup = false }\n", read(folder .. "config.lua"))
    end)

    it("warns about a wrong value and gives its default", function()
        write(folder .. "config.lua", "return { range_m = 'far' }\n")
        local cfg = config_file.load(SCHEMA, log, folder)
        assert.are.equal(15, cfg.range_m)
        assert.are.equal(1, #logged)
        assert.matches("^WARN config range_m: ", logged[1])
    end)

    it("warns and gives the defaults for a config.lua that does not load", function()
        write(folder .. "config.lua", "return {\n")
        local cfg = config_file.load(SCHEMA, log, folder)
        assert.are.same({ log_pickup = true, range_m = 15 }, cfg)
        assert.matches("^WARN config: cannot read ", logged[1])
    end)

    it("warns and gives the defaults for a config.lua that returns no table", function()
        write(folder .. "config.lua", "return 3\n")
        config_file.load(SCHEMA, log, folder)
        assert.matches("^WARN config: cannot read .*using the defaults: 3$", logged[1])
    end)

    it("warns and gives the defaults when it cannot write config.lua", function()
        local cfg = config_file.load(SCHEMA, log, folder .. "missing/")
        assert.are.same({ log_pickup = true, range_m = 15 }, cfg)
        assert.matches("^WARN config: cannot write ", logged[1])
    end)
end)
