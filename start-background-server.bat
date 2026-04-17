@echo off
setlocal

cd /d "%~dp0"

where ruby >nul 2>nul
if errorlevel 1 (
  echo Ruby is not installed or not added to PATH.
  echo Install Ruby for Windows, then run this file again.
  pause
  exit /b 1
)

echo Starting Visitor Island Monitor in background...
echo.
echo This computer:
echo   http://localhost:4567
echo.
echo Other computers on the same network:
echo   http://YOUR-PC-IP:4567
echo.
echo The server will keep running after this launcher closes.
echo Use stop-background-server.bat when you want to stop it.
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$alreadyRunning = Get-CimInstance Win32_Process | Where-Object { $_.Name -match '^ruby' -and $_.CommandLine -like '*server.rb*' -and $_.CommandLine -like '*network-shared-app*' }; if ($alreadyRunning) { exit 10 }; Start-Process -FilePath 'ruby' -ArgumentList 'server.rb' -WorkingDirectory '%cd%' -WindowStyle Hidden"

if errorlevel 10 (
  echo The background server already appears to be running.
) else if errorlevel 1 (
  echo Could not start the background server.
  pause
  exit /b 1
) else (
  echo Background server started.
  start "" http://localhost:4567
)

echo.
pause
