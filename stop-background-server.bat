@echo off
setlocal

cd /d "%~dp0"

echo Stopping Visitor Island Monitor background server...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$processes = Get-CimInstance Win32_Process | Where-Object { $_.Name -match '^ruby' -and $_.CommandLine -like '*server.rb*' -and $_.CommandLine -like '*network-shared-app*' }; if (-not $processes) { exit 10 }; $processes | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"

if errorlevel 10 (
  echo No matching background server was found.
) else if errorlevel 1 (
  echo Could not stop the background server.
  pause
  exit /b 1
) else (
  echo Background server stopped.
)

echo.
pause
