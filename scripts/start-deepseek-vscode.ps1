param(
    [ValidateSet("deepseek-pro", "deepseek-flash")]
    [string]$Model = "deepseek-pro",

    [string]$BaseUrl = "http://127.0.0.1:4000",

    [string]$DeepSeekProxyUrl = "",

    [string]$IsolationRoot = "",

    [ValidateSet("danger-full-access", "workspace-write", "read-only")]
    [string]$SandboxMode = "danger-full-access",

    [ValidateSet("never", "on-request", "on-failure", "untrusted")]
    [string]$ApprovalPolicy = "never",

    [ValidateSet("auto", "off")]
    [string]$ResponseLanguage = "auto",

    [string[]]$ResidentContextPath = @("README.md", "src", "scripts", "vscode-extension"),

    [string]$ResidentContextPrompt = "Resident project context for DeepSeek Codex. Preserve architecture, entrypoints, proxy behavior, chat commands, usage notes, and known risks.",

    [int]$ResidentContextMaxInputTokens = 180000,

    [int]$ResidentContextMaxFileBytes = 1000000,

    [switch]$SkipResidentContext,

    [switch]$RestartProxy,

    [switch]$RestartIsolatedVsCode,

    [switch]$ResetVsCodeState,

    [switch]$ProxyOnly,

    [switch]$CliOnly,

    [switch]$PrepareOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $PSCommandPath
$ProjectRoot = Split-Path -Parent $ScriptDir
$ProjectRootForToml = $ProjectRoot
if ([string]::IsNullOrWhiteSpace($IsolationRoot)) {
    $IsolationRoot = Join-Path $env:LOCALAPPDATA "DeepSeekCodex"
}
$IsolationRoot = [System.IO.Path]::GetFullPath($IsolationRoot)
$CodexHome = Join-Path $IsolationRoot "codex-home"
$VsCodeUserDataDir = Join-Path $ProjectRoot ".vscode-deepseek-user-data"
$ConfigPath = Join-Path $CodexHome "config.toml"
$RealCodexConfigPath = Join-Path $env:USERPROFILE ".codex\config.toml"
$ProxyOutLog = Join-Path $ProjectRoot "deepseek-vscode-proxy.out.log"
$ProxyErrLog = Join-Path $ProjectRoot "deepseek-vscode-proxy.err.log"
$ProxyStateDir = Join-Path $ProjectRoot ".deepseek"
$ActiveModelStateFile = Join-Path $ProxyStateDir "active-model.txt"
$ResidentContextFile = Join-Path $ProxyStateDir "resident-context.md"
$BaseUrl = $BaseUrl.TrimEnd("/")
$DeepSeekProxyUrl = $DeepSeekProxyUrl.Trim()
$ProxyUri = [System.Uri]$BaseUrl
$HealthUrl = "$BaseUrl/health"

$UpstreamModel = switch ($Model) {
    "deepseek-pro" { "deepseek-v4-pro" }
    "deepseek-flash" { "deepseek-v4-flash" }
}

function Resolve-CodeLauncher {
    $candidate = Join-Path $env:LOCALAPPDATA "Programs\Microsoft VS Code\bin\code.cmd"
    if (Test-Path -LiteralPath $candidate) {
        return $candidate
    }

    $runningCode = Get-CimInstance Win32_Process -Filter "Name='Code.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath } |
        Select-Object -First 1
    if ($runningCode -and (Test-Path -LiteralPath $runningCode.ExecutablePath)) {
        $installRoot = Split-Path -Parent $runningCode.ExecutablePath
        $candidate = Join-Path $installRoot "bin\code.cmd"
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    $command = Get-Command "code.cmd" -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $command = Get-Command "code" -ErrorAction SilentlyContinue
    if ($command -and $command.Source -like "*.cmd") {
        return $command.Source
    }

    $command = Get-Command "Code.exe" -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $candidate = Join-Path $env:LOCALAPPDATA "Programs\Microsoft VS Code\Code.exe"
    if (Test-Path -LiteralPath $candidate) {
        return $candidate
    }

    throw "Could not find VS Code launcher. Install VS Code or add code.cmd/Code.exe to PATH."
}

function Resolve-CodexCli {
    $command = Get-Command "codex" -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $candidate = Join-Path $env:USERPROFILE ".vscode\extensions\openai.chatgpt-26.506.31421-win32-x64\bin\windows-x86_64\codex.exe"
    if (Test-Path -LiteralPath $candidate) {
        return $candidate
    }

    $extension = Get-ChildItem -Path (Join-Path $env:USERPROFILE ".vscode\extensions") -Directory -Filter "openai.chatgpt-*-win32-x64" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($extension) {
        $candidate = Join-Path $extension.FullName "bin\windows-x86_64\codex.exe"
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    throw "Could not find Codex CLI. Install the Codex VS Code extension or add codex to PATH."
}

function Stop-PortProcess {
    param([int]$Port)

    $lines = netstat -ano | Select-String ":$Port\s"
    foreach ($line in $lines) {
        if ($line.ToString() -match "\sLISTENING\s+(\d+)$") {
            $processId = [int]$Matches[1]
            if ($processId -gt 0) {
                Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Test-ProxyHealth {
    try {
        Invoke-RestMethod -Uri $HealthUrl -TimeoutSec 3 | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function Add-NoProxyEntry {
    param([string]$Name)

    $existing = [Environment]::GetEnvironmentVariable($Name, "Process")
    $entries = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($existing)) {
        foreach ($entry in ($existing -split ",")) {
            $trimmed = $entry.Trim()
            if ($trimmed) {
                $entries.Add($trimmed)
            }
        }
    }

    foreach ($entry in @("127.0.0.1", "localhost", "::1")) {
        if (-not ($entries | Where-Object { $_ -ieq $entry })) {
            $entries.Add($entry)
        }
    }

    [Environment]::SetEnvironmentVariable($Name, ($entries.ToArray() -join ","), "Process")
}

function Stop-IsolatedVsCode {
    $escapedUserDataDir = [regex]::Escape($VsCodeUserDataDir)
    $allProcesses = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
    $rootProcesses = $allProcesses |
        Where-Object { $_.CommandLine -match $escapedUserDataDir }
    $processIds = New-Object System.Collections.Generic.HashSet[int]

    foreach ($process in $rootProcesses) {
        [void]$processIds.Add([int]$process.ProcessId)
    }

    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($process in $allProcesses) {
            if ($process.ParentProcessId -and $processIds.Contains([int]$process.ParentProcessId)) {
                if ($processIds.Add([int]$process.ProcessId)) {
                    $changed = $true
                }
            }
        }
    }

    foreach ($processId in $processIds) {
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
    }

    foreach ($process in $rootProcesses) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Assert-PathUnderDirectory {
    param(
        [string]$BaseDirectory,
        [string]$TargetPath
    )

    $baseFull = [System.IO.Path]::GetFullPath($BaseDirectory).TrimEnd("\") + "\"
    $targetFull = [System.IO.Path]::GetFullPath($TargetPath)
    if (-not $targetFull.StartsWith($baseFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove path outside isolated VS Code user data: $targetFull"
    }
}

function Remove-IsolatedVsCodeStatePath {
    param([string]$RelativePath)

    $target = Join-Path $VsCodeUserDataDir $RelativePath
    if (Test-Path -LiteralPath $target) {
        Assert-PathUnderDirectory -BaseDirectory $VsCodeUserDataDir -TargetPath $target
        Remove-Item -LiteralPath $target -Recurse -Force
        Write-Host "Removed isolated VS Code state: $RelativePath"
    }
}

function Reset-IsolatedVsCodeState {
    New-Item -ItemType Directory -Force -Path $VsCodeUserDataDir | Out-Null

    foreach ($relativePath in @(
        "User\workspaceStorage",
        "User\History",
        "Backups",
        "Session Storage",
        "Local Storage",
        "WebStorage"
    )) {
        Remove-IsolatedVsCodeStatePath -RelativePath $relativePath
    }
}

function Set-IsolatedVsCodeSettings {
    $settingsDir = Join-Path $VsCodeUserDataDir "User"
    $settingsPath = Join-Path $settingsDir "settings.json"
    New-Item -ItemType Directory -Force -Path $settingsDir | Out-Null

    $settings = [ordered]@{}
    if (Test-Path -LiteralPath $settingsPath) {
        try {
            $existing = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
            foreach ($property in $existing.PSObject.Properties) {
                $settings[$property.Name] = $property.Value
            }
        }
        catch {
            Write-Warning "Could not parse isolated VS Code settings.json; rewriting it."
        }
    }

    $settings["chatgpt.localeOverride"] = "zh-CN"
    $settings["http.proxySupport"] = "off"

    $json = $settings | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($settingsPath, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

function Write-IsolatedConfig {
    New-Item -ItemType Directory -Force -Path $CodexHome | Out-Null
    $syncedBlocks = Get-PluginConfigBlocks

$configToml = @"
model = "$UpstreamModel"
model_provider = "deepseek"
model_reasoning_effort = "medium"
sandbox_mode = "$SandboxMode"
approval_policy = "$ApprovalPolicy"

[windows]
sandbox = "elevated"

[projects.'$ProjectRootForToml']
trust_level = "trusted"

[profiles.deepseek-flash]
model = "deepseek-v4-flash"
model_provider = "deepseek"
model_reasoning_effort = "medium"

[profiles.deepseek-pro]
model = "deepseek-v4-pro"
model_provider = "deepseek"
model_reasoning_effort = "medium"

[model_providers.deepseek]
name = "DeepSeek"
base_url = "$BaseUrl"
env_key = "DEEPSEEK_API_KEY"
wire_api = "responses"
$syncedBlocks
"@

    [System.IO.File]::WriteAllText($ConfigPath, $configToml, [System.Text.UTF8Encoding]::new($false))
}

function Get-PluginConfigBlocks {
    if (-not (Test-Path -LiteralPath $RealCodexConfigPath)) {
        return ""
    }

    $lines = [System.IO.File]::ReadAllLines($RealCodexConfigPath)
    $result = New-Object System.Collections.Generic.List[string]
    $copy = $false

    foreach ($line in $lines) {
        if ($line -match '^\s*\[') {
            $copy = $line -match '^\s*\[(plugins|marketplaces|mcp|mcp_servers|mcpServers|connectors)\.'
        }

        if ($copy) {
            $result.Add($line)
        }
    }

    if ($result.Count -eq 0) {
        return ""
    }

    return ([Environment]::NewLine + ($result.ToArray() -join [Environment]::NewLine) + [Environment]::NewLine)
}

function Update-ResidentContext {
    if ($SkipResidentContext) {
        Write-Host "Resident context refresh skipped."
        return
    }

    $contextScript = Join-Path $ScriptDir "deepseek-long-context.ps1"
    if (-not (Test-Path -LiteralPath $contextScript)) {
        Write-Warning "Resident context script not found: $contextScript"
        return
    }

    $existingPaths = @()
    foreach ($item in $ResidentContextPath) {
        if (-not [string]::IsNullOrWhiteSpace($item) -and (Test-Path -LiteralPath (Join-Path $ProjectRoot $item))) {
            $existingPaths += $item
        }
    }

    if ($existingPaths.Count -eq 0) {
        Write-Warning "Resident context refresh skipped because no configured paths exist."
        return
    }

    New-Item -ItemType Directory -Force -Path $ProxyStateDir | Out-Null
    & $contextScript `
        -Path $existingPaths `
        -Prompt $ResidentContextPrompt `
        -ContextOutput $ResidentContextFile `
        -MaxInputTokens $ResidentContextMaxInputTokens `
        -MaxFileBytes $ResidentContextMaxFileBytes
}

Set-Location $ProjectRoot
Write-IsolatedConfig
Update-ResidentContext

if ($PrepareOnly) {
    Write-Host "Prepared isolated DeepSeek Codex config."
    Write-Host "  Config: $ConfigPath"
    Write-Host "  CODEX_HOME: $CodexHome"
    Write-Host "  Model: $Model ($UpstreamModel)"
    Write-Host "  Sandbox: $SandboxMode"
    Write-Host "  Approval policy: $ApprovalPolicy"
    Write-Host "  Response language: $ResponseLanguage"
    Write-Host "  Resident context: $ResidentContextFile"
    Write-Host "  Proxy: $BaseUrl"
    if (-not [string]::IsNullOrWhiteSpace($DeepSeekProxyUrl)) {
        Write-Host "  DeepSeek upstream proxy: $DeepSeekProxyUrl"
    }
    return
}

$userDeepSeekApiKey = [Environment]::GetEnvironmentVariable("DEEPSEEK_API_KEY", "User")
if ([string]::IsNullOrWhiteSpace($userDeepSeekApiKey)) {
    throw "Windows user environment variable DEEPSEEK_API_KEY is not set."
}

$codeLauncher = $null
if (-not $CliOnly) {
    $codeLauncher = Resolve-CodeLauncher
}
$env:DEEPSEEK_API_KEY = $userDeepSeekApiKey
$env:CODEX_HOME = $CodexHome
$env:LOG_REQUESTS = "1"
$env:DEEPSEEK_RESPONSE_LANGUAGE = $ResponseLanguage
New-Item -ItemType Directory -Force -Path $ProxyStateDir | Out-Null
[System.IO.File]::WriteAllText($ActiveModelStateFile, $UpstreamModel + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
$env:DEEPSEEK_ACTIVE_MODEL = $UpstreamModel
$env:DEEPSEEK_ACTIVE_MODEL_STATE_FILE = $ActiveModelStateFile
$env:DEEPSEEK_RESIDENT_CONTEXT_FILE = $ResidentContextFile
Add-NoProxyEntry -Name "NO_PROXY"
Add-NoProxyEntry -Name "no_proxy"
if (-not [string]::IsNullOrWhiteSpace($DeepSeekProxyUrl)) {
    $env:DEEPSEEK_UPSTREAM_PROXY = $DeepSeekProxyUrl
}
else {
    Remove-Item Env:\DEEPSEEK_UPSTREAM_PROXY -ErrorAction SilentlyContinue
}

if ($ProxyUri.Host -in @("127.0.0.1", "localhost", "::1")) {
    $env:DEEPSEEK_PROXY_HOST = $ProxyUri.Host
    $env:DEEPSEEK_PROXY_PORT = [string]$ProxyUri.Port
}

if ((-not (Test-ProxyHealth)) -or $RestartProxy -or (-not [string]::IsNullOrWhiteSpace($DeepSeekProxyUrl))) {
    Write-Host "Starting local DeepSeek Responses proxy on $BaseUrl..."
    if ($ProxyUri.Host -in @("127.0.0.1", "localhost", "::1")) {
        Stop-PortProcess -Port $ProxyUri.Port
    }

    Remove-Item $ProxyOutLog, $ProxyErrLog -ErrorAction SilentlyContinue
    Start-Process `
        -FilePath "node" `
        -ArgumentList ".\src\deepseek-responses-proxy.mjs" `
        -WorkingDirectory $ProjectRoot `
        -RedirectStandardOutput $ProxyOutLog `
        -RedirectStandardError $ProxyErrLog `
        -WindowStyle Hidden | Out-Null

    $healthy = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-ProxyHealth) {
            $healthy = $true
            break
        }
    }

    if (-not $healthy) {
        throw "DeepSeek proxy did not become healthy. Check $ProxyErrLog"
    }
}
else {
    Write-Host "DeepSeek proxy is already healthy on $HealthUrl."
}

New-Item -ItemType Directory -Force -Path $VsCodeUserDataDir | Out-Null

if ($RestartIsolatedVsCode) {
    Stop-IsolatedVsCode
    Start-Sleep -Milliseconds 800
}

if ($ResetVsCodeState) {
    Reset-IsolatedVsCodeState
}

Set-IsolatedVsCodeSettings

Write-Host ""
if ($CliOnly) {
    Write-Host "Preparing isolated Codex CLI for DeepSeek."
} else {
    Write-Host "Launching isolated VS Code for DeepSeek Codex."
}
Write-Host "  CODEX_HOME: $CodexHome"
Write-Host "  VS Code user data: $VsCodeUserDataDir"
if (-not $CliOnly) {
    Write-Host "  VS Code launcher: $codeLauncher"
}
Write-Host "  Model: $Model ($UpstreamModel)"
Write-Host "  Sandbox: $SandboxMode"
Write-Host "  Approval policy: $ApprovalPolicy"
Write-Host "  Response language: $ResponseLanguage"
Write-Host "  Reset VS Code state: $ResetVsCodeState"
Write-Host "  Active model state: $ActiveModelStateFile"
Write-Host "  Resident context: $ResidentContextFile"
Write-Host "  Proxy: $BaseUrl"
Write-Host "  NO_PROXY: $env:NO_PROXY"
if (-not [string]::IsNullOrWhiteSpace($DeepSeekProxyUrl)) {
    Write-Host "  DeepSeek upstream proxy: $DeepSeekProxyUrl"
}

if ($ProxyOnly) {
    Write-Host ""
    Write-Host "DeepSeek proxy is ready. VS Code was not launched because -ProxyOnly was set."
    return
}

if ($CliOnly) {
    $codexCli = Resolve-CodexCli
    Write-Host ""
    Write-Host "Launching Codex CLI with isolated DeepSeek CODEX_HOME."
    Write-Host "  Codex CLI: $codexCli"
    & $codexCli
    return
}

Write-Host ""
Write-Host "This does not modify the real Codex config: $RealCodexConfigPath"

& $codeLauncher --new-window --user-data-dir $VsCodeUserDataDir $ProjectRoot
