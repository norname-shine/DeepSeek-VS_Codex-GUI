@echo off
setlocal
chcp 65001 >nul

pushd "%~dp0" >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install-vscode-extension.ps1"
set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" (
  echo.
  echo VS Code extension install failed. See the error above.
  pause
)

popd >nul
exit /b %EXIT_CODE%
