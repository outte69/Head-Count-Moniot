@echo off
setlocal

cd /d "%~dp0"

where powershell >nul 2>nul
if errorlevel 1 (
  echo PowerShell is not available on this Windows computer.
  pause
  exit /b 1
)

echo Starting Visitor Island Monitor without Ruby...
echo.
echo Open on this computer:
echo   http://localhost:4567
echo.
echo This launcher uses localhost only, so it does not need admin rights.
echo For office network sharing, use start-server-no-ruby-network.bat
echo.
echo Leave this window open while the app is in use.
echo Press Ctrl+C to stop the server.
echo.

start "" cmd /c "ping -n 3 127.0.0.1 >nul && start http://localhost:4567"
powershell -ExecutionPolicy Bypass -File "%~dp0server.ps1"

echo.
echo Server stopped.
pause
