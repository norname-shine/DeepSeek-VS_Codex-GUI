@echo off
setlocal

cd /d "%~dp0"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-deepseek-codex.ps1"
if errorlevel 1 (
  echo.
  echo DeepSeek Codex launcher failed. See the error above.
  pause
)

endlocal
