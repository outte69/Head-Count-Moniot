@echo off
setlocal

cd /d "%~dp0"

echo Starting Visitor Island Monitor background server without Ruby...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$processes = Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'powershell' -and $_.CommandLine -like '*server.ps1*' -and $_.CommandLine -like '*network-shared-app*' -and $_.CommandLine -notlike '*AllowNetwork*' }; if ($processes) { exit 10 }; Start-Process -FilePath 'powershell' -ArgumentList '-ExecutionPolicy Bypass -File ""%cd%\server.ps1""' -WorkingDirectory '%cd%' -WindowStyle Hidden"

if errorlevel 10 (
  echo The background PowerShell server already appears to be running.
) else if errorlevel 1 (
  echo Could not start the background PowerShell server.
  pause
  exit /b 1
) else (
  echo Background PowerShell server started.
  start "" http://localhost:4567
)

echo.
pause
