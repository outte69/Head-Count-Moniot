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

echo Starting Visitor Island Monitor shared server...
echo.
echo Open this on the same computer:
echo   http://localhost:4567
echo.
echo Open this on other computers in the same network:
echo   http://YOUR-PC-IP:4567
echo.
echo Leave this window open while the app is being used.
echo Press Ctrl+C to stop the server.
echo.

start "" cmd /c "ping -n 3 127.0.0.1 >nul && start http://localhost:4567"

ruby server.rb

echo.
echo Server stopped.
pause
