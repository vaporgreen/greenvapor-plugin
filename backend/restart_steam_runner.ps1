param([switch]$Worker)

$taskName = 'SteamRestartHelper'

function Get-SteamExe {
    $steam = Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue

    if ($steam.SteamExe) {
        return ([string]$steam.SteamExe).Trim('"')
    }

    if ($steam.SteamPath) {
        return Join-Path $steam.SteamPath 'steam.exe'
    }

    foreach ($key in @(
        'HKLM:\Software\WOW6432Node\Valve\Steam',
        'HKLM:\Software\Valve\Steam'
    )) {
        $path = (Get-ItemProperty $key -ErrorAction SilentlyContinue).InstallPath
        if ($path) {
            return Join-Path $path 'steam.exe'
        }
    }
}

if ($Worker) {
    Start-Sleep 2

    $steamExe = Get-SteamExe
    if (-not $steamExe -or -not (Test-Path -LiteralPath $steamExe)) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        exit 1
    }

    Start-Process `
        -FilePath $steamExe `
        -ArgumentList '-shutdown' `
        -WindowStyle Hidden

    for ($i = 0; $i -lt 30; $i++) {
        if (-not (Get-Process steam -ErrorAction SilentlyContinue)) {
            break
        }

        Start-Sleep 1
    }

    Get-Process steam -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue

    Start-Sleep 2

    Start-Process `
        -FilePath $steamExe `
        -WorkingDirectory (Split-Path -Parent $steamExe)

    Unregister-ScheduledTask `
        -TaskName $taskName `
        -Confirm:$false `
        -ErrorAction SilentlyContinue

    exit
}

$script = $MyInvocation.MyCommand.Path
$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -Worker"

$trigger = New-ScheduledTaskTrigger `
    -Once `
    -At (Get-Date).AddMinutes(5)

$principal = New-ScheduledTaskPrincipal `
    -UserId $user `
    -LogonType Interactive `
    -RunLevel Limited

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Force | Out-Null

Start-ScheduledTask $taskName
