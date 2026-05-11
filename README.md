# DeepSeek Codex Responses Proxy

This folder contains a small Node.js proxy that lets Codex keep its OpenAI
Responses API provider shape while forwarding compatible requests to
DeepSeek's Chat Completions API.

## What is configured

The main Codex config keeps GPT as the default model:

```toml
model = "gpt-5.5"
model_reasoning_effort = "medium"
```

DeepSeek is available as an optional profile:

```toml
[profiles.deepseek]
model = "deepseek-v4-flash"
model_provider = "deepseek"

[profiles.deepseek-flash]
model = "deepseek-v4-flash"
model_provider = "deepseek"

[profiles.deepseek-pro]
model = "deepseek-v4-pro"
model_provider = "deepseek"

[model_providers.deepseek]
name = "DeepSeek"
base_url = "https://obvious-relationships-pam-northeast.trycloudflare.com"
env_key = "DEEPSEEK_API_KEY"
wire_api = "responses"
```

The API key is read from the Windows user environment variable
`DEEPSEEK_API_KEY`; the raw key should not be stored in `config.toml`.

## Start the proxy

```powershell
$env:DEEPSEEK_API_KEY = [Environment]::GetEnvironmentVariable("DEEPSEEK_API_KEY", "User")
$env:LOG_REQUESTS = "1"
node .\src\deepseek-responses-proxy.mjs
```

Health check:

```powershell
Invoke-RestMethod http://127.0.0.1:4000/health
```

## Optional HTTPS tunnel

Codex on this Windows setup did not reliably reach `127.0.0.1`, so the current
config uses a Cloudflare quick tunnel that forwards to the local proxy.

```powershell
.\tools\cloudflared.exe tunnel --url http://127.0.0.1:4000 --no-autoupdate
```

Quick tunnel URLs are temporary. If the URL changes, update
`C:\Users\Administrator\.codex\config.toml` under
`[model_providers.deepseek].base_url`.

## Use DeepSeek

From VS Code:

1. Run `install-vscode-extension.bat`.
2. Restart VS Code.
3. Open Command Palette and run one of:
   - `DeepSeek Codex: Pick Model and Launch`
   - `DeepSeek Codex: Launch V4 Flash`
   - `DeepSeek Codex: Launch V4 Pro`

The extension launches DeepSeek Codex in a VS Code terminal. It does not replace
the official OpenAI Codex chat panel.

On this Windows setup the DeepSeek launcher starts Codex with
`--dangerously-bypass-approvals-and-sandbox`, because the Codex Windows command
runner can fail with `0xc0000022`. Use it only for local workspaces you trust.

Double-click:

```text
start-deepseek-codex.bat
```

The BAT starts the proxy, starts a Cloudflare quick tunnel, updates the DeepSeek
`base_url` in Codex config, asks whether to use Flash or Pro, and then launches
Codex with the selected profile.

Manual launch:

```powershell
codex -p deepseek-flash
codex -p deepseek-pro
```

Non-interactive smoke test:

```powershell
$env:DEEPSEEK_API_KEY = [Environment]::GetEnvironmentVariable("DEEPSEEK_API_KEY", "User")
codex -p deepseek-flash exec --skip-git-repo-check "Reply with exactly OK"
```

## Current scope

The proxy translates text, streaming deltas, and function tool calls between
Codex Responses-style requests and DeepSeek Chat Completions. It is still a
compatibility bridge, not a native Codex provider. Keep GPT as the default for
high-confidence coding work, and use DeepSeek explicitly when you want to test
or compare it.

DeepSeek V4 thinking mode is disabled by default in the proxy because Codex
tool-call turns do not preserve DeepSeek's `reasoning_content` field. Enable it
only for experiments:

```powershell
$env:DEEPSEEK_THINKING = "1"
```
