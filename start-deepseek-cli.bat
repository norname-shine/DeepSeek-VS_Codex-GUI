@echo off
setlocal
chcp 65001 >nul

pushd "%~dp0" >nul

set "FIRST_ARG=%~1"
set "SECOND_ARG=%~2"

if /I "%FIRST_ARG%"=="help" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-deepseek-vscode.ps1" -CliOnly -CliCommand help
  goto done
)
if /I "%FIRST_ARG%"=="doctor" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-deepseek-vscode.ps1" -CliOnly -CliCommand doctor
  goto done
)
if /I "%FIRST_ARG%"=="switch" (
  if /I "%SECOND_ARG%"=="pro" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-deepseek-vscode.ps1" -CliOnly -CliCommand switch-pro
    goto done
  )
  if /I "%SECOND_ARG%"=="flash" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-deepseek-vscode.ps1" -CliOnly -CliCommand switch-flash
    goto done
  )
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-deepseek-vscode.ps1" -CliOnly -CliCommand switch
  goto done
)
if /I "%FIRST_ARG%"=="switch-pro" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-deepseek-vscode.ps1" -CliOnly -CliCommand switch-pro
  goto done
)
if /I "%FIRST_ARG%"=="switch-flash" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-deepseek-vscode.ps1" -CliOnly -CliCommand switch-flash
  goto done
)
if /I "%FIRST_ARG%"=="model" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-deepseek-vscode.ps1" -CliOnly -CliCommand model
  goto done
)
if /I "%FIRST_ARG%"=="context" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-deepseek-vscode.ps1" -CliOnly -CliCommand context
  goto done
)
if /I "%FIRST_ARG%"=="think" (
  if /I "%SECOND_ARG%"=="off" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-deepseek-vscode.ps1" -CliOnly -CliCommand think-off
    goto done
  )
  if /I "%SECOND_ARG%"=="high" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-deepseek-vscode.ps1" -CliOnly -CliCommand think-high
    goto done
  )
  if /I "%SECOND_ARG%"=="max" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-deepseek-vscode.ps1" -CliOnly -CliCommand think-max
    goto done
  )
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-deepseek-vscode.ps1" -CliOnly -CliCommand think
  goto done
)
if /I "%FIRST_ARG%"=="think-off" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-deepseek-vscode.ps1" -CliOnly -CliCommand think-off
  goto done
)
if /I "%FIRST_ARG%"=="think-high" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-deepseek-vscode.ps1" -CliOnly -CliCommand think-high
  goto done
)
if /I "%FIRST_ARG%"=="think-max" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-deepseek-vscode.ps1" -CliOnly -CliCommand think-max
  goto done
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-deepseek-vscode.ps1" -CliOnly %*

:done
set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" (
  echo.
  echo Isolated DeepSeek Codex CLI failed. See the error above.
  pause
)

popd >nul
exit /b %EXIT_CODE%
