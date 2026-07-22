local m_utils = require("utils")
local fs = require("fs")
local http_client = require("http_client")
local config = require("config")
local logger = require("plugin_logger")
local paths = require("paths")
local utils = require("plugin_utils")
local steam_utils = require("steam_utils")

local auto_update = {}

function auto_update.check_for_updates_now(is_manual)
    local cfg_path = paths.backend_path(config.UPDATE_CONFIG_FILE)
    local cfg = utils.read_json(cfg_path)
    
    local ts_path = fs.join(paths.get_plugin_dir(), "data", "update_last_check.txt")
    local agora = os.time()
    local ultima_checagem = 0
    
    if fs.exists(ts_path) then
        local ts_content = utils.read_text(ts_path)
        local unix_string = ts_content:match("Timestamp:%s*(%d+)")
        ultima_checagem = tonumber(unix_string) or 0
    end

    local intervalo_segundos = 6 * 60 * 60 -- 6 horas

    -- Se NÃO for clique manual no botão e fez checagem em menos de 6 horas, ignora
    if not is_manual and (agora - ultima_checagem) < intervalo_segundos then
        local current_version = utils.get_plugin_version()
        return { 
            success = true, 
            message = "Up-to-date (Checagem recente ignorada. Versão: " .. current_version .. ")" 
        }
    end
    
    local latest_version = ""
    local zip_url = ""
    
    local gh_cfg = cfg.github
    if gh_cfg then
        local owner = gh_cfg.owner or ""
        local repo = gh_cfg.repo or ""
        local asset_name = gh_cfg.asset_name or "greenvapor.zip"
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
        
        if resp and resp.status == 403 then
            return { success = false, error = "GitHub API Rate Limit atingido. Aguarde alguns minutos." }
        elseif resp and resp.status ~= 200 then
            return { success = false, error = "Erro na API do GitHub. Status: " .. tostring(resp.status) }
        end

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
            
            -- Atualiza o timestamp apenas se a requisição teve sucesso
            local data_humana = os.date("%d/%m/%Y %H:%M:%S", agora)
            local texto_para_salvar = string.format(
                "Ultima checagem feita em: %s\nTimestamp: %d\nNao altere este arquivo.", 
                data_humana, 
                agora
            )
            utils.write_text(ts_path, texto_para_salvar)
        end
    end
    
    if latest_version == "" or zip_url == "" then
        return { success = false, error = "Manifest missing version or zip_url" }
    end
    
    local current_version = utils.get_plugin_version()

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
    local plugin_dir = paths.get_plugin_dir()
    local is_windows = m_utils.getenv("OS") == "Windows_NT"
    local cmd
    
    if is_windows then
        -- Baixa e extrai via PowerShell (totalmente oculto e sem abrir janelas CMD)
        local ps_cmd = string.format(
            'Invoke-WebRequest -Uri "%s" -OutFile "%s" -UserAgent "GreenVapor-Updater"; Expand-Archive -Path "%s" -DestinationPath "%s" -Force',
            zip_url, pending_zip, pending_zip, plugin_dir
        )
        cmd = string.format('powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "%s"', ps_cmd)
    else
        cmd = string.format('curl -L -o "%s" "%s" && unzip -o -q "%s" -d "%s"', pending_zip, zip_url, pending_zip, plugin_dir)
    end
    
    m_utils.exec(cmd)
    if fs.exists(pending_zip) then fs.remove(pending_zip) end
    
    local msg = "GreenVapor atualizado para a versão " .. latest_version .. ". Por favor, reinicie a Steam."
    return { success = true, message = msg }
end

function auto_update.restart_steam()
    local is_windows = m_utils.getenv("OS") == "Windows_NT"
    if is_windows then
        local script_path = paths.backend_path("restart_steam_runner.ps1")
        if fs.exists(script_path) then
            m_utils.exec(
                'cmd.exe /C start "" /b powershell.exe -NoProfile -NonInteractive ' ..
                '-ExecutionPolicy Bypass -WindowStyle Hidden ' ..
                '-File "' .. script_path .. '"'
            )
            return true
        end
        local cmd_path = paths.backend_path("restart_steam.cmd")
        if fs.exists(cmd_path) then
            m_utils.exec('start /b cmd /C "' .. cmd_path .. '"')
            return true
        end
    else
        m_utils.exec("killall steam && steam &")
        return true
    end
    return false
end

function auto_update.apply_pending_update_if_any()
    return ""
end

function auto_update.run_async_background_check()
    logger.info("Iniciando verificação automática de updates pós-login...")
    local result = auto_update.check_for_updates_now()
end

return auto_update