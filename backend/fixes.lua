local m_utils = require("utils")
local fs = require("fs")
local http_client = require("http_client")
local config = require("config")
local logger = require("plugin_logger")
local utils = require("plugin_utils")
local paths = require("paths")
local steam_utils = require("steam_utils")
local cjson = require("json")

local fixes = {}

local FIXES_INDEX_URL       = "https://index.luatools.work/fixes-index.json"
local FIXES_INDEX_PROXY_URL = "https://luatools.vercel.app/fixes-index.json"
local FIXES_DATA_FILE       = "data/installed_fixes.json"
local FIXES_INDEX_CACHE_FILE = "data/fixes_index_cache.json"
local FIXES_CACHE_MAX_AGE   = 86400  -- 24 hours in seconds

-- In-memory state
local PENDING_FIX_INFO  = {}
local UNFIX_STATE       = {}
local _FIXES_INDEX_CACHE = nil  -- in-memory copy for the current session

-- ── Persistence helpers ───────────────────────────────────────────────────────

local function ensure_data_dir()
    local dir = paths.backend_path("data")
    if not fs.exists(dir) then fs.create_directories(dir) end
end

local function load_fixes_index_disk_cache()
    local path = paths.backend_path(FIXES_INDEX_CACHE_FILE)
    if not fs.exists(path) then return nil end
    local cached = utils.read_json(path)
    if type(cached) ~= "table" or type(cached.index) ~= "table" then return nil end
    local saved_at = tonumber(cached.saved_at) or 0
    local now = 0
    local ok, t = pcall(os.time)
    if ok then now = t end
    if (now - saved_at) > FIXES_CACHE_MAX_AGE then
        logger.log("GreenVapor: fixes index disk cache expired, will re-fetch")
        return nil
    end
    return cached.index
end

local function save_fixes_index_disk_cache(index_data)
    ensure_data_dir()
    local now = 0
    local ok, t = pcall(os.time)
    if ok then now = t end
    utils.write_json(paths.backend_path(FIXES_INDEX_CACHE_FILE), {
        saved_at = now,
        index    = index_data
    })
end

local function get_fixes_data()
    local path = paths.backend_path(FIXES_DATA_FILE)
    if not fs.exists(path) then return { fixes = {} } end
    local data = utils.read_json(path)
    if type(data) ~= "table" then return { fixes = {} } end
    if type(data.fixes) ~= "table" then data.fixes = {} end
    return data
end

local function save_fixes_data(data)
    ensure_data_dir()
    utils.write_json(paths.backend_path(FIXES_DATA_FILE), data)
end

local function record_installed_fix(appid, info)
    appid = tonumber(appid)
    local data = get_fixes_data()
    local new_list = {}
    for _, f in ipairs(data.fixes) do
        if tonumber(f.appid) ~= appid then
            table.insert(new_list, f)
        end
    end
    local date_str = ""
    local ok, d = pcall(os.date, "%Y-%m-%d")
    if ok and d then date_str = d end
    table.insert(new_list, {
        appid       = appid,
        gameName    = info.gameName or ("Unknown Game (" .. tostring(appid) .. ")"),
        fixType     = info.fixType or "generic",
        installPath = info.installPath or "",
        date        = date_str
    })
    data.fixes = new_list
    save_fixes_data(data)
    logger.log("GreenVapor: Recorded fix for appid=" .. tostring(appid))
end

local function remove_installed_fix(appid)
    appid = tonumber(appid)
    local data = get_fixes_data()
    local new_list = {}
    for _, f in ipairs(data.fixes) do
        if tonumber(f.appid) ~= appid then
            table.insert(new_list, f)
        end
    end
    data.fixes = new_list
    save_fixes_data(data)
end

-- ── Public API ────────────────────────────────────────────────────────────────

function fixes.check_for_fixes(appid)
    if type(appid) == "string" then appid = tonumber(appid) end
    local result = {
        success  = true,
        appid    = appid,
        gameName = "Unknown Game (" .. tostring(appid) .. ")",
        genericFix = { status = 0, available = false },
        onlineFix  = { status = 0, available = false }
    }

    -- 1. In-memory cache (same session)
    local data = _FIXES_INDEX_CACHE

    -- 2. Disk cache (survives Steam restarts, avoids rate limiting)
    if not data then
        data = load_fixes_index_disk_cache()
        if data then
            _FIXES_INDEX_CACHE = data
            logger.log("GreenVapor: fixes index loaded from disk cache")
        end
    end

    -- 3. Fetch from network
    if not data then
        local req_opts = {
            timeout = 10,
            headers = { ["User-Agent"] = config.USER_AGENT }
        }
        local resp = http_client.get(FIXES_INDEX_URL, req_opts)
        if not (resp and resp.status == 200 and resp.body) then
            logger.warn("GreenVapor: fixes index primary failed (status=" ..
                tostring(resp and resp.status or "nil") .. "), trying proxy")
            resp = http_client.get(FIXES_INDEX_PROXY_URL, req_opts)
        end
        if resp and resp.status == 200 and resp.body then
            data = utils.decode_json(resp.body)
            if type(data) == "table" then
                _FIXES_INDEX_CACHE = data
                pcall(save_fixes_index_disk_cache, data)
                logger.log("GreenVapor: fixes index fetched and cached (" ..
                    tostring(#(data.genericFixes or {})) .. " generic, " ..
                    tostring(#(data.onlineFixes or {})) .. " online)")
            end
        end
    end

    local generic_url = "https://files.luatools.work/GameBypasses/" .. tostring(appid) .. ".zip"
    local online_url  = "https://files.luatools.work/OnlineFix1/"   .. tostring(appid) .. ".zip"
    local head_opts   = { timeout = 5, headers = { ["User-Agent"] = config.USER_AGENT } }

    if type(data) == "table" then
        -- Use the index (fast path: no extra requests per game)
        for _, v in ipairs(data.genericFixes or {}) do
            if tonumber(v) == appid then
                result.genericFix = { status = 200, available = true, url = generic_url }
                break
            end
        end
        if not result.genericFix.available then result.genericFix.status = 404 end

        for _, v in ipairs(data.onlineFixes or {}) do
            if tonumber(v) == appid then
                result.onlineFix = { status = 200, available = true, url = online_url }
                break
            end
        end
        if not result.onlineFix.available then result.onlineFix.status = 404 end
    else
        -- Fallback: HEAD requests per file (same as Python original when index unavailable)
        logger.log("GreenVapor: index unavailable, falling back to HEAD requests for appid=" .. tostring(appid))
        local gr = http_client.head(generic_url, head_opts)
        if not (gr and gr.status == 200) then
            gr = http_client.get(generic_url, head_opts)
        end
        if gr and gr.status == 200 then
            result.genericFix = { status = 200, available = true, url = generic_url }
        else
            result.genericFix.status = gr and gr.status or 0
        end

        local or_ = http_client.head(online_url, head_opts)
        if not (or_ and or_.status == 200) then
            or_ = http_client.get(online_url, head_opts)
        end
        if or_ and or_.status == 200 then
            result.onlineFix = { status = 200, available = true, url = online_url }
        else
            result.onlineFix.status = or_ and or_.status or 0
        end
    end

    return result
end

function fixes.apply_game_fix(appid, download_url, install_path, fix_type, game_name)
    appid = tonumber(appid)

    -- Store metadata so we can record the fix when extraction completes
    PENDING_FIX_INFO[appid] = {
        installPath = install_path or "",
        fixType     = fix_type or "generic",
        gameName    = game_name or ("Unknown Game (" .. tostring(appid) .. ")"),
        runnerPath  = "",
        vbsPath     = ""
    }

    local dest_root = utils.ensure_temp_download_dir()
    local dest_zip  = fs.join(dest_root, "fix_" .. tostring(appid) .. ".zip")
    local state_file = fs.join(dest_root, "fix_" .. tostring(appid) .. "_state.json")

    logger.log("GreenVapor: ApplyGameFix appid=" .. tostring(appid) .. " type=" .. tostring(fix_type))
    m_utils.write_file(state_file, '{"status":"downloading"}')

    local is_win = (m_utils.getenv("OS") or ""):find("Windows") ~= nil
    if is_win then
        local ps1 = fs.join(paths.get_plugin_dir(), "backend", "scripts", "downloader.ps1")

        -- Use backslashes for all paths so PowerShell and wscript.exe accept them unambiguously
        local function to_win(p) return (p or ""):gsub("/", "\\") end
        local ps1_win      = to_win(ps1)
        local dest_zip_win = to_win(dest_zip)
        local state_win    = to_win(state_file)
        local install_win  = to_win(install_path)

        local runner_path = dest_root .. "\\fix_runner_" .. tostring(appid) .. ".ps1"
        local runner_content = string.format(
            '& "%s" -Url "%s" -DestPath "%s" -ExtractDir "%s" -StateFile "%s"',
            ps1_win, download_url, dest_zip_win, install_win, state_win
        )
        m_utils.write_file(runner_path, runner_content)
        PENDING_FIX_INFO[appid].runnerPath = runner_path

        -- Launch via wscript.exe (graphical host) so Windows Terminal cannot intercept it.
        -- oShell.Run with window-style 0 produces a truly hidden process on all Windows versions.
        local runner_win = to_win(runner_path)
        local vbs_path   = dest_root .. "\\fix_runner_" .. tostring(appid) .. ".vbs"
        local vbs_content = string.format(
            'Set oShell = CreateObject("Wscript.Shell")\r\n' ..
            'oShell.Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ""%s""", 0, False\r\n',
            runner_win
        )
        m_utils.write_file(vbs_path, vbs_content)
        PENDING_FIX_INFO[appid].vbsPath = vbs_path

        m_utils.exec('wscript.exe "' .. to_win(vbs_path) .. '"')
    else
        local sh = fs.join(paths.get_plugin_dir(), "backend", "scripts", "downloader.sh")
        m_utils.exec('chmod +x "' .. sh .. '"')
        local cmd = string.format(
            'nohup bash "%s" "%s" "%s" "%s" "%s" > /dev/null 2>&1 &',
            sh, download_url, dest_zip, install_path, state_file
        )
        m_utils.exec(cmd)
    end

    return { success = true }
end

function fixes.get_apply_status(appid)
    appid = tonumber(appid)
    local dest_root  = utils.ensure_temp_download_dir()
    local state_file = fs.join(dest_root, "fix_" .. tostring(appid) .. "_state.json")
    local dest_zip   = fs.join(dest_root, "fix_" .. tostring(appid) .. ".zip")

    if not fs.exists(state_file) then
        return { success = true, state = { status = "done" } }
    end

    local content = m_utils.read_file(state_file)
    if not (content and content ~= "") then
        return { success = true, state = { status = "downloading" } }
    end
    -- Strip UTF-8 BOM written by .NET Framework's System.Text.Encoding.UTF8
    if content:sub(1, 3) == "\xEF\xBB\xBF" then content = content:sub(4) end

    local ok, data = pcall(cjson.decode, content)
    if not (ok and type(data) == "table" and data.status) then
        return { success = true, state = { status = "downloading" } }
    end

    if data.status == "extracted" then
        -- Extraction done: record the fix in persistent storage
        local pending = PENDING_FIX_INFO[appid] or {}
        pcall(record_installed_fix, appid, pending)
        PENDING_FIX_INFO[appid] = nil
        data.status = "done"
        pcall(fs.remove, state_file)
        pcall(fs.remove, dest_zip)
        if pending.runnerPath and pending.runnerPath ~= "" then pcall(fs.remove, pending.runnerPath) end
        if pending.vbsPath    and pending.vbsPath    ~= "" then pcall(fs.remove, pending.vbsPath)    end
    elseif data.status == "failed" then
        PENDING_FIX_INFO[appid] = nil
        pcall(fs.remove, state_file)
    elseif data.status == "cancelled" then
        PENDING_FIX_INFO[appid] = nil
        pcall(fs.remove, state_file)
        pcall(fs.remove, dest_zip)
    end

    return { success = true, state = data }
end

function fixes.cancel_apply_fix(appid)
    appid = tonumber(appid)
    local dest_root  = utils.ensure_temp_download_dir()
    local state_file = fs.join(dest_root, "fix_" .. tostring(appid) .. "_state.json")

    -- Clear pending info so the background download (if it completes) doesn't get recorded
    PENDING_FIX_INFO[appid] = nil

    if fs.exists(state_file) then
        m_utils.write_file(state_file, '{"status":"cancelled","error":"Cancelled by user"}')
    end

    logger.log("GreenVapor: CancelApplyFix appid=" .. tostring(appid))
    return { success = true }
end

function fixes.get_installed_fixes()
    local data = get_fixes_data()
    return { success = true, fixes = data.fixes or {} }
end

function fixes.unfix_game(appid, install_path, fix_date)
    appid = tonumber(appid)
    UNFIX_STATE[appid] = { status = "processing" }

    logger.log("GreenVapor: UnfixGame appid=" .. tostring(appid))

    local ok, err = pcall(remove_installed_fix, appid)
    if not ok then
        logger.warn("GreenVapor: UnfixGame failed to remove record: " .. tostring(err))
        UNFIX_STATE[appid] = { status = "failed", error = tostring(err) }
        return { success = false, error = tostring(err) }
    end

    UNFIX_STATE[appid] = { status = "done" }
    return { success = true }
end

function fixes.get_unfix_status(appid)
    appid = tonumber(appid)
    local state = UNFIX_STATE[appid] or { status = "done" }
    return { success = true, state = state }
end

function fixes.uninstall_fix(appid)
    return fixes.unfix_game(tonumber(appid), "", "")
end

return fixes
