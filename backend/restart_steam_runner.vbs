Set oShell = CreateObject("Wscript.Shell")
oShell.Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ""c:\program files (x86)\steam\millennium\plugins\greenvapor\backend\restart_steam_runner.ps1""", 0, False
