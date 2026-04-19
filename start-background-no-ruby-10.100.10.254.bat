@echo off
setlocal

cd /d "%~dp0"

echo Starting Visitor Island Monitor background mode on 10.100.10.254 without Ruby...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$processes = Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'powershell' -and $_.CommandLine -like '*server.ps1*' -and $_.CommandLine -like '*10.100.10.254*' -and $_.CommandLine -like '*network-shared-app*' }; if ($processes) { exit 10 }; Start-Process -FilePath 'powershell' -ArgumentList '-ExecutionPolicy Bypass -File ""%cd%\server.ps1"" -BindHost ""10.100.10.254""' -WorkingDirectory '%cd%' -WindowStyle Hidden"

if errorlevel 10 (
  echo The background server for 10.100.10.254 already appears to be running.
) else if errorlevel 1 (
  echo Could not start the background server on 10.100.10.254.
  echo IT may need to allow the Windows URL reservation for that IP and port.
  pause
  exit /b 1
) else (
  echo Background server started on 10.100.10.254.
  start "" http://10.100.10.254:4567
)

echo.
pause
