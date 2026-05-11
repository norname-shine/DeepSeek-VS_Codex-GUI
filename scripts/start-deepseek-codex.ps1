param(
  [ValidateSet("", "deepseek-flash", "deepseek-pro")]
  [string]$CodexProfile = ""
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$ConfigPath = Join-Path $env:USERPROFILE ".codex\config.toml"
$ProxyLog = Join-Path $Root "deepseek-proxy.err.log"
$ProxyOut = Join-Path $Root "deepseek-proxy.out.log"
$TunnelLog = Join-Path $Root "cloudflared.err.log"
$TunnelOut = Join-Path $Root "cloudflared.out.log"
$Cloudflared = Join-Path $Root "tools\cloudflared.exe"

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

function Stop-LocalCloudflared {
  if (-not (Test-Path $Cloudflared)) {
    throw "Missing cloudflared.exe at $Cloudflared"
  }

  $resolved = (Resolve-Path $Cloudflared).Path
  Get-Process cloudflared -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $resolved } |
    Stop-Process -Force -ErrorAction SilentlyContinue
}

function Get-TunnelUrlFromLog {
  param([string]$LogPath)

  if (Test-Path $LogPath) {
    $content = Get-Content -Raw $LogPath
    $match = [regex]::Match($content, "https://[a-zA-Z0-9-]+\.trycloudflare\.com")
    if ($match.Success) {
      return $match.Value
    }
  }

  return $null
}

function Get-ConfiguredTunnelUrl {
  if (-not (Test-Path $ConfigPath)) {
    return $null
  }

  $config = Get-Content -Raw $ConfigPath
  $match = [regex]::Match($config, 'base_url = "(https://[a-zA-Z0-9-]+\.trycloudflare\.com)"')
  if ($match.Success) {
    return $match.Groups[1].Value
  }

  return $null
}

function Test-TunnelUrl {
  param([string]$Url)

  if ([string]::IsNullOrWhiteSpace($Url)) {
    return $false
  }

  try {
    $response = Invoke-RestMethod "$Url/health" -TimeoutSec 8
    return [bool]$response.ok
  } catch {
    return $false
  }
}

function Start-CloudflareTunnel {
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    Write-Host "      Cloudflare quick tunnel attempt $attempt/3..."
    Stop-LocalCloudflared
    Remove-Item $TunnelLog, $TunnelOut -ErrorAction SilentlyContinue
    Start-Process -FilePath $Cloudflared `
      -ArgumentList @("tunnel", "--url", "http://127.0.0.1:4000", "--no-autoupdate") `
      -WorkingDirectory $Root `
      -WindowStyle Hidden `
      -RedirectStandardError $TunnelLog `
      -RedirectStandardOutput $TunnelOut

    for ($i = 0; $i -lt 60; $i++) {
      Start-Sleep -Seconds 1
      $url = Get-TunnelUrlFromLog -LogPath $TunnelLog
      if ($url) {
        return $url
      }

      if (Test-Path $TunnelLog) {
        $content = Get-Content -Raw $TunnelLog
        if ($content -match "failed to unmarshal quick Tunnel|Internal Server Error|status_code=`"500") {
          break
        }
      }
    }
  }

  $existingUrl = Get-ConfiguredTunnelUrl
  if (Test-TunnelUrl -Url $existingUrl) {
    Write-Host "      Reusing existing tunnel URL from config."
    return $existingUrl
  }

  $lastLog = if (Test-Path $TunnelLog) { (Get-Content -Tail 20 $TunnelLog) -join "`n" } else { "(no cloudflared log)" }
  throw "Cloudflare quick tunnel did not return a usable URL after 3 attempts. Last cloudflared log:`n$lastLog"
}

function Update-CodexConfigBaseUrl {
  param([string]$Url)

  if (-not (Test-Path $ConfigPath)) {
    throw "Codex config not found: $ConfigPath"
  }

  $config = Get-Content -Raw $ConfigPath
  $updated = $config -replace 'base_url = "https://[^"]+\.trycloudflare\.com"', "base_url = `"$Url`""

  if ($updated -eq $config -and $config -notmatch '\[model_providers\.deepseek\]') {
    throw "DeepSeek provider block was not found in $ConfigPath"
  }

  Set-Content -Path $ConfigPath -Value $updated -Encoding UTF8
}

function Resolve-CodexExe {
  $command = Get-Command "codex.exe" -ErrorAction SilentlyContinue
  if ($command -and (Test-Path $command.Source)) {
    return $command.Source
  }

  $extensionRoot = Join-Path $env:USERPROFILE ".vscode\extensions"
  if (Test-Path $extensionRoot) {
    $candidate = Get-ChildItem -Path $extensionRoot -Recurse -Filter "codex.exe" -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -match "openai\.chatgpt" } |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 1

    if ($candidate) {
      return $candidate.FullName
    }
  }

  throw "Could not find codex.exe. Open Codex once from VS Code, or add codex.exe to PATH."
}

$apiKey = [Environment]::GetEnvironmentVariable("DEEPSEEK_API_KEY", "User")
if ([string]::IsNullOrWhiteSpace($apiKey)) {
  throw "DEEPSEEK_API_KEY is not set in the Windows user environment."
}

$CodexExe = Resolve-CodexExe
Set-Location $Root

if ([string]::IsNullOrWhiteSpace($CodexProfile)) {
  Write-Host "Choose DeepSeek model profile:"
  Write-Host "  1. deepseek-flash  (deepseek-v4-flash, default)"
  Write-Host "  2. deepseek-pro    (deepseek-v4-pro)"
  $choice = Read-Host "Select 1 or 2"
  $CodexProfile = if ($choice -eq "2") { "deepseek-pro" } else { "deepseek-flash" }
}
Write-Host "Using Codex profile: $CodexProfile"
Write-Host ""

Write-Host "[1/4] Starting local DeepSeek Responses proxy..."
Stop-PortProcess -Port 4000
Remove-Item $ProxyLog, $ProxyOut -ErrorAction SilentlyContinue
$env:DEEPSEEK_API_KEY = $apiKey
$env:LOG_REQUESTS = "1"
$env:DEEPSEEK_PROXY_HOST = "127.0.0.1"
Start-Process -FilePath "node.exe" `
  -ArgumentList @(".\src\deepseek-responses-proxy.mjs") `
  -WorkingDirectory $Root `
  -WindowStyle Hidden `
  -RedirectStandardError $ProxyLog `
  -RedirectStandardOutput $ProxyOut

Start-Sleep -Seconds 1
$health = Invoke-RestMethod "http://127.0.0.1:4000/health"
if (-not $health.ok) {
  throw "DeepSeek proxy health check failed."
}

Write-Host "[2/4] Starting Cloudflare quick tunnel..."
$tunnelUrl = Start-CloudflareTunnel
Write-Host "[3/4] Updating Codex DeepSeek base_url:"
Write-Host "      $tunnelUrl"
Update-CodexConfigBaseUrl -Url $tunnelUrl

Write-Host "[4/4] Launching Codex with DeepSeek profile..."
Write-Host "      $CodexExe"
Write-Host "      profile: $CodexProfile"
Write-Host ""
Write-Host "Close this window when you are done. Proxy logs:"
Write-Host "  $ProxyLog"
Write-Host "  $TunnelLog"
Write-Host ""

if ($env:SKIP_CODEX_LAUNCH -eq "1") {
  Write-Host "SKIP_CODEX_LAUNCH=1, not launching Codex."
  return
}

& $CodexExe -p $CodexProfile --dangerously-bypass-approvals-and-sandbox
