@echo off
setlocal

cd /d "%~dp0"

if not exist "..\visitor-island-monitor-data-entry.html" (
  echo Could not find visitor-island-monitor-data-entry.html
  echo Make sure this launcher stays inside the network-shared-app folder.
  pause
  exit /b 1
)

echo Opening Visitor Island Monitor standalone local app...
echo.
echo This version opens directly in the browser and avoids server errors.
echo It is for one computer only and does not share live data over the network.
echo.

start "" "..\visitor-island-monitor-data-entry.html"

echo The standalone app has been opened.
echo.
pause
