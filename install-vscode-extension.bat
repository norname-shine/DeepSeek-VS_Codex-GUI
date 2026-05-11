@echo off
setlocal

cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install-vscode-extension.ps1"
if errorlevel 1 (
  echo.
  echo VS Code extension install failed. See the error above.
  pause
)

endlocal
