param(
    [string]$Url,
    [Parameter(Mandatory = $true)][string]$DestPath,
    [Parameter(Mandatory = $true)][string]$ExtractDir,
    [string]$StateFile,
    [string]$UserAgent = "discord(dot)gg/greenvapor"
)

$ErrorActionPreference = 'Stop'

$utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Write-State($json) {
    if ([string]::IsNullOrWhiteSpace($StateFile)) { return }
    [System.IO.File]::WriteAllText($StateFile, $json, $utf8NoBom)
}

try {
    # ── Download ──────────────────────────────────────────────────────────
    if (-not [string]::IsNullOrWhiteSpace($Url)) {
        Write-State '{"status":"downloading","bytesRead":0,"totalBytes":0}'

        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.UserAgent = $UserAgent
        $req.Method   = "GET"
        $req.AllowAutoRedirect = $true
        $resp = $req.GetResponse()
        $totalBytes = $resp.ContentLength    # -1 if server omits Content-Length

        $respStream = $resp.GetResponseStream()
        $fileStream = [System.IO.File]::Create($DestPath)
        $buffer     = New-Object byte[] 65536   # 64 KB chunks
        $bytesRead  = [long]0
        $lastReport = [long]0

        while ($true) {
            $read = $respStream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { break }
            $fileStream.Write($buffer, 0, $read)
            $bytesRead += $read
            # Report every ~256 KB to avoid excess disk writes
            if (($bytesRead - $lastReport) -ge 262144) {
                $lastReport = $bytesRead
                Write-State ("{`"status`":`"downloading`",`"bytesRead`":" + $bytesRead + ",`"totalBytes`":" + $totalBytes + "}")
            }
        }
        $fileStream.Close()
        $respStream.Close()
        $resp.Close()
        # Final state with accurate totals
        Write-State ("{`"status`":`"downloading`",`"bytesRead`":" + $bytesRead + ",`"totalBytes`":" + [Math]::Max($totalBytes, $bytesRead) + "}")
    }

    # ── Extract ───────────────────────────────────────────────────────────
    if (-not [string]::IsNullOrWhiteSpace($ExtractDir)) {
        Write-State '{"status":"extracting"}'

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($DestPath)

        # Mirror Python logic: if every file lives under a single numeric top-level
        # folder (the appid), strip that prefix so files land directly in ExtractDir.
        $topDirs = @{}
        foreach ($entry in $zip.Entries) {
            $slash = $entry.FullName.IndexOf('/')
            if ($slash -gt 0) {
                $topDirs[$entry.FullName.Substring(0, $slash)] = 1
            } elseif ($entry.FullName -ne '') {
                $topDirs[$entry.FullName] = 1
            }
        }
        $stripPrefix = $null
        if ($topDirs.Count -eq 1) {
            $folderName = @($topDirs.Keys)[0]
            if ($folderName -match '^\d+$') { $stripPrefix = $folderName + '/' }
        }

        foreach ($entry in $zip.Entries) {
            if ($entry.Name -eq '') { continue }   # directory entry — skip

            $rel = $entry.FullName
            if ($stripPrefix -and $rel.StartsWith($stripPrefix)) {
                $rel = $rel.Substring($stripPrefix.Length)
            }
            if (-not $rel) { continue }

            $target = [System.IO.Path]::Combine($ExtractDir, $rel.Replace('/', '\'))
            $dir    = [System.IO.Path]::GetDirectoryName($target)
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
        $zip.Dispose()
        Write-State '{"status":"extracted"}'
    } else {
        Write-State '{"status":"done"}'
    }
}
catch {
    if (-not [string]::IsNullOrWhiteSpace($StateFile)) {
        $errMsg = $_.Exception.Message.Replace('\', '\\').Replace('"', '\"')
        Write-State ("{`"status`":`"failed`",`"error`":`"" + $errMsg + "`"}")
    }
    exit 1
}
