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

    [string[]]$ResidentContextPath = @(),

    [string]$ResidentContextPrompt = "Optional resident project background for DeepSeek Codex. Treat Codex chat-window context, attached files, selected code, tool results, and the latest user message as authoritative.",

    [int]$ResidentContextMaxInputTokens = 180000,

    [int]$ResidentContextMaxFileBytes = 1000000,

    [switch]$EnableResidentContext,

    [switch]$SkipResidentContext,

    [switch]$RestartProxy,

    [switch]$RestartIsolatedVsCode,

    [switch]$ResetVsCodeState,

    [switch]$ProxyOnly,

    [switch]$CliOnly,

    [ValidateSet("", "help", "switch", "switch-pro", "switch-flash", "model", "context", "think", "think-off", "think-high", "think-max")]
    [string]$CliCommand = "",

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
$ThinkingModeStateFile = Join-Path $ProxyStateDir "thinking-mode.txt"
$ProxyContextModeStateFile = Join-Path $ProxyStateDir "proxy-context-mode.txt"
$ResidentContextFile = Join-Path $ProxyStateDir "resident-context.md"
$BaseUrl = $BaseUrl.TrimEnd("/")
$DeepSeekProxyUrl = $DeepSeekProxyUrl.Trim()
$ProxyUri = [System.Uri]$BaseUrl
$HealthUrl = "$BaseUrl/health"

$UpstreamModel = switch ($Model) {
    "deepseek-pro" { "deepseek-v4-pro" }
    "deepseek-flash" { "deepseek-v4-flash" }
}
$ModelExplicit = $PSBoundParameters.ContainsKey("Model")
$ResidentContextPathExplicit = $PSBoundParameters.ContainsKey("ResidentContextPath")

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
model_reasoning_effort = "high"
sandbox_mode = "$SandboxMode"
approval_policy = "$ApprovalPolicy"

[windows]
sandbox = "elevated"

[projects.'$ProjectRootForToml']
trust_level = "trusted"

[profiles.deepseek-flash]
model = "deepseek-v4-flash"
model_provider = "deepseek"
model_reasoning_effort = "high"

[profiles.deepseek-pro]
model = "deepseek-v4-pro"
model_provider = "deepseek"
model_reasoning_effort = "high"

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

function Add-ExistingContextPath {
    param(
        [System.Collections.Generic.List[string]]$Paths,
        [string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        return
    }

    $fullPath = Join-Path $ProjectRoot $RelativePath
    if (Test-Path -LiteralPath $fullPath) {
        $normalized = $RelativePath -replace '\\', '/'
        if (-not $Paths.Contains($normalized)) {
            $Paths.Add($normalized) | Out-Null
        }
    }
}

function Add-DiscoveredContextFiles {
    param(
        [System.Collections.Generic.List[string]]$Paths,
        [string]$Pattern
    )

    $excludedParts = @(
        ".git",
        ".deepseek",
        ".vscode-deepseek-user-data",
        ".codex-deepseek-vscode",
        "node_modules"
    )

    Get-ChildItem -LiteralPath $ProjectRoot -Recurse -File -Filter $Pattern -ErrorAction SilentlyContinue |
        Where-Object {
            $relative = [System.IO.Path]::GetRelativePath($ProjectRoot, $_.FullName) -replace '\\', '/'
            foreach ($part in $excludedParts) {
                if ($relative -eq $part -or $relative.StartsWith("$part/")) {
                    return $false
                }
            }
            return $true
        } |
        ForEach-Object {
            $relative = [System.IO.Path]::GetRelativePath($ProjectRoot, $_.FullName) -replace '\\', '/'
            if (-not $Paths.Contains($relative)) {
                $Paths.Add($relative) | Out-Null
            }
        }
}

function Get-DefaultResidentContextPaths {
    $paths = [System.Collections.Generic.List[string]]::new()

    foreach ($relativePath in @(
        "README.md",
        "AGENTS.md",
        "CLAUDE.md",
        "GEMINI.md",
        ".cursorrules",
        ".windsurfrules",
        ".github/copilot-instructions.md",
        ".cursor/rules",
        ".codex/rules",
        ".codex/instructions.md",
        ".codex/skills"
    )) {
        Add-ExistingContextPath -Paths $paths -RelativePath $relativePath
    }

    Add-DiscoveredContextFiles -Paths $paths -Pattern "SKILL.md"
    Add-DiscoveredContextFiles -Paths $paths -Pattern "*.rules.md"
    Add-DiscoveredContextFiles -Paths $paths -Pattern "*.instructions.md"

    return $paths.ToArray()
}

function Update-ResidentContext {
    if (-not $ResidentContextEnabled) {
        Write-Host "Resident project context disabled. Codex chat-window context will be used."
        return
    }

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

function Read-ActiveModel {
    if (Test-Path -LiteralPath $ActiveModelStateFile) {
        $value = (Get-Content -LiteralPath $ActiveModelStateFile -Raw).Trim()
        if ($value -in @("deepseek-v4-pro", "deepseek-v4-flash")) {
            return $value
        }
    }

    return $UpstreamModel
}

function Write-ActiveModel {
    param([string]$Value)

    New-Item -ItemType Directory -Force -Path $ProxyStateDir | Out-Null
    [System.IO.File]::WriteAllText($ActiveModelStateFile, $Value + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

function Update-IsolatedConfigModel {
    param([string]$Value)

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        return
    }

    $content = Get-Content -LiteralPath $ConfigPath -Raw
    $rootModelPattern = [regex]::new('(?m)^model = "deepseek-v4-(pro|flash)"$')
    $content = $rootModelPattern.Replace($content, "model = `"$Value`"", 1)
    $content = [regex]::Replace($content, '(?m)^model_reasoning_effort = "medium"$', 'model_reasoning_effort = "high"')
    [System.IO.File]::WriteAllText($ConfigPath, $content, [System.Text.UTF8Encoding]::new($false))
}

function Set-ActiveModel {
    param([string]$Value)

    Write-ActiveModel -Value $Value
    Update-IsolatedConfigModel -Value $Value
}

function Read-ThinkingMode {
    if (Test-Path -LiteralPath $ThinkingModeStateFile) {
        $value = (Get-Content -LiteralPath $ThinkingModeStateFile -Raw).Trim()
        if ($value -in @("disabled", "high", "max")) {
            return $value
        }
    }

    return "disabled"
}

function Write-ThinkingMode {
    param([string]$Value)

    $normalized = switch ($Value) {
        "off" { "disabled" }
        "disabled" { "disabled" }
        "max" { "max" }
        default { "high" }
    }

    New-Item -ItemType Directory -Force -Path $ProxyStateDir | Out-Null
    [System.IO.File]::WriteAllText($ThinkingModeStateFile, $normalized + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

function Read-ProxyContextMode {
    if (Test-Path -LiteralPath $ProxyContextModeStateFile) {
        return (Get-Content -LiteralPath $ProxyContextModeStateFile -Raw).Trim()
    }

    return ""
}

function Write-ProxyContextMode {
    param([string]$Value)

    New-Item -ItemType Directory -Force -Path $ProxyStateDir | Out-Null
    [System.IO.File]::WriteAllText($ProxyContextModeStateFile, $Value + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

function Invoke-CliCommand {
    switch ($CliCommand) {
        "help" {
            Write-Host "DeepSeek Codex CLI commands:"
            Write-Host "  start-deepseek-cli.bat switch        Toggle Pro / Flash"
            Write-Host "  start-deepseek-cli.bat switch-pro    Switch to DeepSeek V4 Pro"
            Write-Host "  start-deepseek-cli.bat switch-flash  Switch to DeepSeek V4 Flash"
            Write-Host "  start-deepseek-cli.bat model         Show active model"
            Write-Host "  start-deepseek-cli.bat context       Show resident context status"
            Write-Host "  start-deepseek-cli.bat think         Toggle thinking high / off"
            Write-Host "  start-deepseek-cli.bat think-off     Disable thinking"
            Write-Host "  start-deepseek-cli.bat think-high    Enable thinking high"
            Write-Host "  start-deepseek-cli.bat think-max     Enable thinking max"
            return $true
        }
        "model" {
            Write-Host "Current model: $(Read-ActiveModel)"
            Write-Host "Thinking mode: $(Read-ThinkingMode)"
            return $true
        }
        "context" {
            if (-not $ResidentContextEnabled) {
                Write-Host "Resident project context: disabled"
                Write-Host "Chat-window context from Codex remains active."
            } elseif (Test-Path -LiteralPath $ResidentContextFile) {
                Write-Host "Resident context: loaded"
                Write-Host "  $ResidentContextFile"
            } else {
                Write-Host "Resident context: missing"
            }
            return $true
        }
        "think" {
            $current = Read-ThinkingMode
            $next = if ($current -eq "disabled") { "high" } else { "disabled" }
            Write-ThinkingMode -Value $next
            Write-Host "Thinking mode: $next."
            return $true
        }
        "think-off" {
            Write-ThinkingMode -Value "disabled"
            Write-Host "Thinking mode: disabled."
            return $true
        }
        "think-high" {
            Write-ThinkingMode -Value "high"
            Write-Host "Thinking mode: high."
            return $true
        }
        "think-max" {
            Write-ThinkingMode -Value "max"
            Write-Host "Thinking mode: max."
            return $true
        }
        "switch" {
            $current = Read-ActiveModel
            $next = if ($current -eq "deepseek-v4-pro") { "deepseek-v4-flash" } else { "deepseek-v4-pro" }
            Set-ActiveModel -Value $next
            Write-Host "Switched to $next."
            Write-Host "Running Codex CLI status text may stay stale until the session is restarted; proxy routing uses this new model immediately."
            return $true
        }
        "switch-pro" {
            Set-ActiveModel -Value "deepseek-v4-pro"
            Write-Host "Switched to deepseek-v4-pro."
            Write-Host "Running Codex CLI status text may stay stale until the session is restarted; proxy routing uses this new model immediately."
            return $true
        }
        "switch-flash" {
            Set-ActiveModel -Value "deepseek-v4-flash"
            Write-Host "Switched to deepseek-v4-flash."
            Write-Host "Running Codex CLI status text may stay stale until the session is restarted; proxy routing uses this new model immediately."
            return $true
        }
    }

    return $false
}

if ((-not $ResidentContextPathExplicit) -and (-not $SkipResidentContext)) {
    $ResidentContextPath = Get-DefaultResidentContextPaths
}
$ResidentContextEnabled = (-not $SkipResidentContext) -and ($EnableResidentContext -or $ResidentContextPathExplicit -or $ResidentContextPath.Count -gt 0)

if ((-not $ModelExplicit) -and (Test-Path -LiteralPath $ActiveModelStateFile)) {
    $UpstreamModel = Read-ActiveModel
    $Model = if ($UpstreamModel -eq "deepseek-v4-flash") { "deepseek-flash" } else { "deepseek-pro" }
}

Set-Location $ProjectRoot
Write-IsolatedConfig

if ($CliOnly -and $CliCommand) {
    if (Invoke-CliCommand) {
        return
    }
}

Update-ResidentContext

if ($PrepareOnly) {
    Write-Host "Prepared isolated DeepSeek Codex config."
    Write-Host "  Config: $ConfigPath"
    Write-Host "  CODEX_HOME: $CodexHome"
    Write-Host "  Model: $Model ($UpstreamModel)"
    Write-Host "  Sandbox: $SandboxMode"
    Write-Host "  Approval policy: $ApprovalPolicy"
    Write-Host "  Response language: $ResponseLanguage"
    if ($ResidentContextEnabled) {
        Write-Host "  Resident project context: $ResidentContextFile"
    } else {
        Write-Host "  Resident project context: disabled; using Codex chat-window context"
    }
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
if (-not (Test-Path -LiteralPath $ActiveModelStateFile) -or -not $CliCommand) {
    Write-ActiveModel -Value $UpstreamModel
}
if (-not (Test-Path -LiteralPath $ThinkingModeStateFile)) {
    Write-ThinkingMode -Value "disabled"
}
$env:DEEPSEEK_ACTIVE_MODEL = $UpstreamModel
$env:DEEPSEEK_ACTIVE_MODEL_STATE_FILE = $ActiveModelStateFile
$env:DEEPSEEK_THINKING_MODE_STATE_FILE = $ThinkingModeStateFile
if ($ResidentContextEnabled) {
    $env:DEEPSEEK_RESIDENT_CONTEXT_FILE = $ResidentContextFile
} else {
    Remove-Item Env:\DEEPSEEK_RESIDENT_CONTEXT_FILE -ErrorAction SilentlyContinue
}
$CurrentProxyContextMode = if ($ResidentContextEnabled) { "resident-project-context" } else { "chat-window-context" }
$ProxyContextModeChanged = (Read-ProxyContextMode) -ne $CurrentProxyContextMode
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

if ((-not (Test-ProxyHealth)) -or $RestartProxy -or $ProxyContextModeChanged -or (-not [string]::IsNullOrWhiteSpace($DeepSeekProxyUrl))) {
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
    Write-ProxyContextMode -Value $CurrentProxyContextMode
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
Write-Host "  Thinking mode: $(Read-ThinkingMode)"
if ($ResidentContextEnabled) {
    Write-Host "  Resident project context: $ResidentContextFile"
} else {
    Write-Host "  Resident project context: disabled; using Codex chat-window context"
}
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
