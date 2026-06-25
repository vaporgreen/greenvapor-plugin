local m_utils = require("utils")
local fs = require("fs")
local http_client = require("http_client")
local config = require("config")
local logger = require("plugin_logger")
local paths = require("paths")
local utils = require("plugin_utils")
local steam_utils = require("steam_utils")

local auto_update = {}

function auto_update.check_for_updates_now()
    local cfg_path = paths.backend_path(config.UPDATE_CONFIG_FILE)
    local cfg = utils.read_json(cfg_path)
    
    local latest_version = ""
    local zip_url = ""
    
    local gh_cfg = cfg.github
    if gh_cfg then
        local owner = gh_cfg.owner or ""
        local repo = gh_cfg.repo or ""
        local asset_name = gh_cfg.asset_name or "ltsteamplugin.zip"
        local tag = gh_cfg.tag or ""
        local tag_prefix = gh_cfg.tag_prefix or ""
        
        local endpoint = "https://api.github.com/repos/" .. owner .. "/" .. repo .. "/releases/latest"
        if tag ~= "" then
            endpoint = "https://api.github.com/repos/" .. owner .. "/" .. repo .. "/releases/tags/" .. tag
        end
        
        local resp = http_client.get(endpoint, {
            headers = {
                ["Accept"] = "application/vnd.github+json",
                ["User-Agent"] = "GreenVapor-Updater"
            },
            timeout = 10
        })
        if resp and resp.status == 200 and resp.body then
            local data = utils.decode_json(resp.body)
            local tag_name = data.tag_name or ""
            latest_version = tag_name or data.name or ""
            if tag_prefix ~= "" and latest_version:sub(1, #tag_prefix) == tag_prefix then
                latest_version = latest_version:sub(#tag_prefix + 1)
            end
            
            for _, asset in ipairs(data.assets or {}) do
                if asset.name == asset_name then
                    zip_url = asset.browser_download_url
                    break
                end
            end
            if zip_url == "" and tag_name ~= "" then
                zip_url = "https://github.com/vaporgreen/greenvapor-plugin/releases/download/" .. tag_name .. "/greenvapor.zip"
            end
        end
    end
    
    if latest_version == "" or zip_url == "" then
        return { success = false, error = "Manifest missing version or zip_url" }
    end
    
    local current_version = utils.get_plugin_version()

    -- Compare version tables component by component (can't use <= on tables in Lua)
    local function compare_versions(a, b)
        local ta = utils.parse_version(a)
        local tb = utils.parse_version(b)
        local len = math.max(#ta, #tb)
        for i = 1, len do
            local ai = ta[i] or 0
            local bi = tb[i] or 0
            if ai < bi then return -1
            elseif ai > bi then return 1
            end
        end
        return 0
    end

    if compare_versions(latest_version, current_version) <= 0 then
        return { success = true, message = "Up-to-date (current " .. current_version .. ")" }
    end
    
    local pending_zip = paths.backend_path(config.UPDATE_PENDING_ZIP)
    
    local is_windows = m_utils.getenv("OS") == "Windows_NT"
    local cmd
    if is_windows then
        cmd = string.format('curl.exe -sL -A "discord(dot)gg/greenvapor" "%s" -o "%s" && tar.exe -xf "%s" -C "%s"', zip_url, pending_zip, pending_zip, paths.get_plugin_dir())
    else
        cmd = string.format('curl -L -o "%s" "%s" && unzip -o -q "%s" -d "%s"', pending_zip, zip_url, pending_zip, paths.get_plugin_dir())
    end
    
    m_utils.exec(cmd)
    
    if fs.exists(pending_zip) then fs.remove(pending_zip) end
    
    local msg = "GreenVapor updated to " .. latest_version .. ". Please restart Steam."
    return { success = true, message = msg }
end

function auto_update.restart_steam()
    local is_windows = (m_utils.getenv("OS") or ""):find("Windows") ~= nil
    if is_windows then
        local steam_path = steam_utils.detect_steam_install_path()
        local steam_exe  = ""
        if steam_path and steam_path ~= "" then
            steam_exe = fs.join(steam_path, "steam.exe")
            steam_exe = steam_exe:gsub("/", "\\")
        end

        -- Write a runner PS1 so quoting/paths are trivial; it must survive Steam dying,
        -- so it's launched via start /B (independent background process)
        local runner_path = paths.backend_path("restart_steam_runner.ps1")
        local lines = {
            "Stop-Process -Name steam -Force -ErrorAction SilentlyContinue",
            "Start-Sleep -Seconds 2",
        }
        if steam_exe ~= "" then
            table.insert(lines, string.format('Start-Process -FilePath "%s"', steam_exe))
        else
            table.insert(lines, 'Start-Process "steam"')
        end
        m_utils.write_file(runner_path, table.concat(lines, "\r\n"))

        -- wscript.exe is a graphical host — Windows Terminal cannot intercept it,
        -- so the PowerShell that restarts Steam runs completely hidden.
        local runner_win = runner_path:gsub("/", "\\")
        local vbs_path   = paths.backend_path("restart_steam_runner.vbs")
        local vbs_content = string.format(
            'Set oShell = CreateObject("Wscript.Shell")\r\n' ..
            'oShell.Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ""%s""", 0, False\r\n',
            runner_win
        )
        m_utils.write_file(vbs_path, vbs_content)
        m_utils.exec('wscript.exe "' .. vbs_path:gsub("/", "\\") .. '"')
        return true
    else
        m_utils.exec("killall steam; sleep 2; steam &")
        return true
    end
end

function auto_update.apply_pending_update_if_any()
    return ""
end

return auto_update
