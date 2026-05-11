@echo off
setlocal
chcp 65001 >nul

pushd "%~dp0" >nul

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-deepseek-vscode.ps1" %*
set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" (
  echo.
  echo Isolated DeepSeek VS Code launcher failed. See the error above.
  pause
)

popd >nul
exit /b %EXIT_CODE%
