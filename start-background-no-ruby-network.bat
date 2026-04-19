@echo off
setlocal

cd /d "%~dp0"

echo Starting Visitor Island Monitor background office network mode without Ruby...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$processes = Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'powershell' -and $_.CommandLine -like '*server.ps1*' -and $_.CommandLine -like '*network-shared-app*' -and $_.CommandLine -like '*0.0.0.0*' }; if ($processes) { exit 10 }; Start-Process -FilePath 'powershell' -ArgumentList '-ExecutionPolicy Bypass -File ""%cd%\server.ps1"" -BindHost ""0.0.0.0""' -WorkingDirectory '%cd%' -WindowStyle Hidden"

if errorlevel 10 (
  echo The background office network PowerShell server already appears to be running.
) else if errorlevel 1 (
  echo Could not start the background office network PowerShell server.
  echo IT may need to allow the Windows URL reservation for port 4567.
  pause
  exit /b 1
) else (
  echo Background office network PowerShell server started.
  start "" http://localhost:4567
)

echo.
pause
