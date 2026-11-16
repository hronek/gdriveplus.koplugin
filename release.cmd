@echo off
rem Double-click to release a new version: see tools\release.ps1.
setlocal
set "PS=powershell.exe"
where pwsh.exe >nul 2>nul && set "PS=pwsh.exe"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\release.ps1" %*
set "CODE=%ERRORLEVEL%"
echo.
pause
exit /b %CODE%
