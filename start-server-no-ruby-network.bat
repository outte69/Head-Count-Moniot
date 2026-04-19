@echo off
setlocal

cd /d "%~dp0"

where powershell >nul 2>nul
if errorlevel 1 (
  echo PowerShell is not available on this Windows computer.
  pause
  exit /b 1
)

echo Starting Visitor Island Monitor office network mode without Ruby...
echo.
echo Open on this computer:
echo   http://localhost:4567
echo.
echo Open on other office computers:
echo   http://YOUR-PC-IP:4567
echo.
echo This mode may need IT to allow the Windows URL reservation for port 4567.
echo Leave this window open while the app is in use.
echo Press Ctrl+C to stop the server.
echo.

start "" cmd /c "ping -n 3 127.0.0.1 >nul && start http://localhost:4567"
powershell -ExecutionPolicy Bypass -File "%~dp0server.ps1" -BindHost "0.0.0.0"

echo.
echo Server stopped.
pause
