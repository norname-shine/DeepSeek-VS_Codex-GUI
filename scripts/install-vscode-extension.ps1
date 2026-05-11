$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$Source = Join-Path $Root "vscode-extension"
$ExtensionsRoot = Join-Path $env:USERPROFILE ".vscode\extensions"
$Target = Join-Path $ExtensionsRoot "local.deepseek-codex-launcher-0.1.0"

if (-not (Test-Path $Source)) {
  throw "Extension source not found: $Source"
}

New-Item -ItemType Directory -Force -Path $ExtensionsRoot | Out-Null

if (Test-Path $Target) {
  Remove-Item -LiteralPath $Target -Recurse -Force
}

Copy-Item -LiteralPath $Source -Destination $Target -Recurse

Write-Host "Installed DeepSeek Codex Launcher to:"
Write-Host "  $Target"
Write-Host ""
Write-Host "Restart VS Code, then run one of these commands from Command Palette:"
Write-Host "  DeepSeek Codex: Pick Model and Launch"
Write-Host "  DeepSeek Codex: Launch V4 Flash"
Write-Host "  DeepSeek Codex: Launch V4 Pro"
