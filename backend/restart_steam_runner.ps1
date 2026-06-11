Stop-Process -Name steam -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Start-Process -FilePath "c:\program files (x86)\steam\steam.exe"