@echo off
setlocal

cd /d "%~dp0"

echo Stopping Visitor Island Monitor background PowerShell server...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$processes = Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'powershell' -and $_.CommandLine -like '*server.ps1*' -and $_.CommandLine -like '*network-shared-app*' }; if (-not $processes) { exit 10 }; $processes | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"

if errorlevel 10 (
  echo No matching background PowerShell server was found.
) else if errorlevel 1 (
  echo Could not stop the background PowerShell server.
  pause
  exit /b 1
) else (
  echo Background PowerShell server stopped.
)

echo.
pause
