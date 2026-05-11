param(
    [string[]]$Path = @("."),
    [string]$Prompt = "Analyze the provided files. Summarize the architecture, key risks, and recommended next steps.",
    [string]$PromptFile = "",
    [ValidateSet("deepseek-v4-pro", "deepseek-v4-flash")]
    [string]$Model = "deepseek-v4-pro",
    [string]$Output = "",
    [string]$ContextOutput = "",
    [int]$MaxInputTokens = 900000,
    [int]$MaxFileBytes = 1000000,
    [string]$DeepSeekProxyUrl = "",
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $PSCommandPath
$ProjectRoot = Split-Path -Parent $ScriptDir
Set-Location $ProjectRoot

if ((-not $DryRun) -and [string]::IsNullOrWhiteSpace($ContextOutput)) {
    $apiKey = [Environment]::GetEnvironmentVariable("DEEPSEEK_API_KEY", "User")
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        throw "Windows user environment variable DEEPSEEK_API_KEY is not set."
    }

    $env:DEEPSEEK_API_KEY = $apiKey
}
if (-not [string]::IsNullOrWhiteSpace($DeepSeekProxyUrl)) {
    $env:DEEPSEEK_UPSTREAM_PROXY = $DeepSeekProxyUrl.Trim()
}

$argsList = @(
    "--model", $Model,
    "--prompt", $Prompt,
    "--max-input-tokens", [string]$MaxInputTokens,
    "--max-file-bytes", [string]$MaxFileBytes
)

foreach ($item in $Path) {
    $argsList += @("--path", $item)
}

if (-not [string]::IsNullOrWhiteSpace($PromptFile)) {
    $argsList += @("--prompt-file", $PromptFile)
}

if (-not [string]::IsNullOrWhiteSpace($Output)) {
    $argsList += @("--output", $Output)
}

if (-not [string]::IsNullOrWhiteSpace($ContextOutput)) {
    $argsList += @("--context-output", $ContextOutput)
}

if ($DryRun) {
    $argsList += "--dry-run"
}

node ".\scripts\deepseek-long-context.mjs" @argsList
