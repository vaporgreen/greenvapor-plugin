-- Freeze / unfreeze a game from Steam updates via OpenSteamTool manifest pinning.
--
-- Strategy: instead of patching the ACF file (which OST overwrites), we write
-- a .lua file into OST's config/lua directory containing setManifestid() calls
-- for every depot found in the game's ACF. OST hot-reloads it immediately.
-- Unfreeze = delete that file (also hot-reloaded by OST).

local m_utils     = require("utils")
local fs          = require("fs")
local cjson       = require("json")
local logger      = require("plugin_logger")
local steam_utils = require("steam_utils")
local paths       = require("paths")

local acf_freeze = {}

local FREEZE_DATA_RELATIVE = "data/ost_frozen_games.json"

local function freeze_data_path()
    return paths.backend_path(FREEZE_DATA_RELATIVE)
end

local function load_freeze_data()
    local p = freeze_data_path()
    if not fs.exists(p) then return {} end
    local text = m_utils.read_file(p)
    if not text or text == "" then return {} end
    local ok, data = pcall(cjson.decode, text)
    return (ok and type(data) == "table") and data or {}
end

local function save_freeze_data(data)
    local dir = paths.backend_path("data")
    if not fs.exists(dir) then pcall(fs.create_directories, dir) end
    local ok, text = pcall(cjson.encode, data)
    if ok then m_utils.write_file(freeze_data_path(), text) end
end

-- Locate OST's lua config dir dynamically from Steam install path.
-- Prefers config/stplug-in (matches [lua] paths in opensteamtool.toml),
-- falls back to config/lua if stplug-in doesn't exist yet.
local function find_ost_lua_dir()
    local steam_path = steam_utils.detect_steam_install_path()
    if steam_path and steam_path ~= "" then
        local preferred = fs.join(steam_path, "config", "stplug-in")
        if fs.exists(preferred) then return preferred end
        -- stplug-in doesn't exist yet; fall back to config/lua
        return fs.join(steam_path, "config", "lua")
    end
    -- Fallback candidates if steam_utils can't detect
    local candidates = {
        "C:\\Program Files (x86)\\Steam\\config\\stplug-in",
        "C:\\Program Files (x86)\\Steam\\config\\lua",
        "C:\\Program Files\\Steam\\config\\stplug-in",
        "C:\\Program Files\\Steam\\config\\lua",
        "D:\\Steam\\config\\stplug-in",
        "D:\\Steam\\config\\lua",
        "E:\\Steam\\config\\stplug-in",
        "E:\\Steam\\config\\lua",
    }
    for _, p in ipairs(candidates) do
        if fs.exists(p) then return p end
    end
    return nil
end

local function ost_freeze_filename(ost_lua_dir, appid)
    return fs.join(ost_lua_dir, "lt_freeze_" .. tostring(appid) .. ".lua")
end

local function find_acf_path(appid)
    local steam_path = steam_utils.detect_steam_install_path()
    if not steam_path or steam_path == "" then return nil end
    local vdf_path = fs.join(steam_path, "config", "libraryfolders.vdf")
    if not fs.exists(vdf_path) then return nil end
    local vdf = m_utils.read_file(vdf_path)
    if not vdf then return nil end
    local acf_name = "appmanifest_" .. tostring(appid) .. ".acf"
    for lib_path in vdf:gmatch('"path"%s+"([^"]+)"') do
        local lp = lib_path:gsub("\\\\", "\\")
        local candidate = fs.join(lp, "steamapps", acf_name)
        if fs.exists(candidate) then return candidate end
    end
    return nil
end

local function parse_installed_depots(content)
    local depots = {}
    local block = content:match('"InstalledDepots"%s*(%b{})')
    if not block then return depots end
    for depotid, body in block:gmatch('"(%d+)"%s*(%b{})') do
        local manifest = body:match('"manifest"%s+"(%d+)"')
        if manifest then depots[depotid] = manifest end
    end
    return depots
end

local function read_key(content, key)
    return content:match('"' .. key .. '"%s+"([^"]*)"')
end

-- Public API --------------------------------------------------------------

function acf_freeze.get_status(appid)
    appid = tonumber(appid)
    if not appid then return { success = false, error = "Invalid appid" } end
    local acf_path = find_acf_path(appid)
    if not acf_path then
        return { success = true, installed = false, frozen = false }
    end
    local content = m_utils.read_file(acf_path) or ""
    local cur_build = tonumber(read_key(content, "buildid") or "0") or 0
    local freeze_data = load_freeze_data()
    local entry = freeze_data[tostring(appid)]
    local is_frozen = entry ~= nil
    return {
        success         = true,
        installed       = true,
        frozen          = is_frozen,
        buildid         = tostring(cur_build),
        frozenBuildid   = is_frozen and entry.buildid   or nil,
        originalBuildid = is_frozen and entry.buildid   or nil,
        frozenAt        = is_frozen and entry.frozen_at or nil,
        newerAvailable  = false,
    }
end

function acf_freeze.freeze(appid)
    appid = tonumber(appid)
    if not appid then return { success = false, error = "Invalid appid" } end

    local acf_path = find_acf_path(appid)
    if not acf_path then return { success = false, error = "Game not installed" } end

    local content = m_utils.read_file(acf_path)
    if not content then return { success = false, error = "Failed to read ACF" } end

    local depots = parse_installed_depots(content)
    local depot_count = 0
    for _ in pairs(depots) do depot_count = depot_count + 1 end
    if depot_count == 0 then
        return { success = false, error = "No installed depots found in ACF" }
    end

    local ost_lua_dir = find_ost_lua_dir()
    if not ost_lua_dir then
        return { success = false, error = "Could not locate OST config/lua directory. Make sure OpenSteamTool is installed." }
    end

    if not fs.exists(ost_lua_dir) then
        local ok, err = pcall(fs.create_directories, ost_lua_dir)
        if not ok then
            return { success = false, error = "Failed to create OST lua dir: " .. tostring(err) }
        end
    end

    local buildid = read_key(content, "buildid") or "0"
    local lines = {
        "-- Auto-generated by GreenVapor Freeze Updates (acf_freeze.lua)",
        "-- App: " .. tostring(appid) .. "  BuildID: " .. buildid,
        "-- DO NOT EDIT - delete this file to unfreeze, or use the GreenVapor Freeze card.",
        "",
    }
    local depot_list = {}
    for depotid, manifest_gid in pairs(depots) do
        lines[#lines + 1] = string.format('setManifestid(%s, "%s")', depotid, manifest_gid)
        depot_list[#depot_list + 1] = { depot = depotid, manifest = manifest_gid }
    end

    local lua_src = table.concat(lines, "\n") .. "\n"
    local freeze_file = ost_freeze_filename(ost_lua_dir, appid)
    local ok, err = pcall(m_utils.write_file, freeze_file, lua_src)
    if not ok then
        return { success = false, error = "Failed to write OST freeze file: " .. tostring(err) }
    end

    local frozen_at = 0
    pcall(function() frozen_at = os.time() end)

    local freeze_data = load_freeze_data()
    freeze_data[tostring(appid)] = {
        freeze_file = freeze_file,
        buildid     = buildid,
        depots      = depot_list,
        frozen_at   = frozen_at,
    }
    save_freeze_data(freeze_data)

    logger.log("acf_freeze: frozen appid=" .. appid .. " buildid=" .. buildid
               .. " depots=" .. depot_count .. " via OST setManifestid")

    return {
        success          = true,
        appid            = appid,
        frozenBuildid    = buildid,
        originalBuildid  = buildid,
        manifestsChanged = depot_count,
        locked           = true,
    }
end

function acf_freeze.unfreeze(appid)
    appid = tonumber(appid)
    if not appid then return { success = false, error = "Invalid appid" } end

    local freeze_data = load_freeze_data()
    local key = tostring(appid)
    local entry = freeze_data[key]
    if not entry then return { success = false, error = "Game is not frozen" } end

    local freeze_file = entry.freeze_file
    if not freeze_file or not fs.exists(freeze_file) then
        local ost_lua_dir = find_ost_lua_dir()
        if ost_lua_dir then
            freeze_file = ost_freeze_filename(ost_lua_dir, appid)
        end
    end

    if freeze_file and fs.exists(freeze_file) then
        local ok, err = pcall(fs.remove, freeze_file)
        if not ok then
            return { success = false, error = "Failed to delete freeze file: " .. tostring(err) }
        end
    end

    freeze_data[key] = nil
    save_freeze_data(freeze_data)

    logger.log("acf_freeze: unfrozen appid=" .. appid .. " (OST lua file deleted, hot-reload will pick it up)")
    return { success = true, appid = appid, note = "Updates unfrozen; OST will hot-reload immediately" }
end

return acf_freeze
