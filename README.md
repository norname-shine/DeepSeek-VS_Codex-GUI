# DeepSeek Codex Bridge

[![中文](https://img.shields.io/badge/README-中文-blue)](#中文版)
[![English](https://img.shields.io/badge/README-English-green)](#english-version)

DeepSeek Codex Bridge connects DeepSeek to the Codex experience in VS Code. It
keeps the normal OpenAI/GPT Codex environment separate, while giving DeepSeek a
stable local bridge, resident project context, and a few short chat commands.

---

## 中文版

[English](#english-version)

### 它解决什么

Codex 的 VS Code 桌面体验很好，但非官方模型接入时常见几个问题：

- 默认上下文不一定稳定传给第三方模型。
- 模型切换需要改配置或重启，流程偏重。
- 网络代理需要和官方 GPT 使用路径分开。
- 不希望影响原本的 Codex / GPT 环境。

这个项目提供一套隔离的 DeepSeek Codex 工作区：启动时准备本地代理、隔离配置、常驻上下文，并保留 VS Code Codex 的可视化工作流。

### 为什么保留 VS Code Codex 桌面端

相比只用 CLI，VS Code Codex 桌面端更适合真实项目开发：

- **文件窗口联动**：对话、文件、diff、跳转在同一个工作区里。
- **拖拽上下文**：文件、图片和选区可以直接交给 Codex 面板。
- **引导式交互**：保留 Codex 的任务引导、权限提示和会话能力。
- **插件 / MCP 入口**：会同步主 Codex 配置里的插件、marketplace、MCP 和 connector 配置块。最终可用工具以 Codex 面板实际显示为准。

### 功能

- DeepSeek V4 Pro / Flash。
- 聊天框短指令：`/D-switch`、`/D-model`、`/D-context`、`/D-help`。
- 默认常驻上下文：启动时生成 `.deepseek/resident-context.md`，每轮请求自动注入。
- 默认中文跟随：中文提问优先用简体中文回答。
- DeepSeek 独立代理出口，不影响正常 GPT / Codex 使用。
- VS Code 隔离 profile，不污染主环境。
- 保留本地 Codex CLI 入口。
- 保留 VS Code launcher extension 安装方式。

### 快速开始

1. 设置 DeepSeek API Key。

   ```powershell
   [Environment]::SetEnvironmentVariable("DEEPSEEK_API_KEY", "your-deepseek-api-key", "User")
   ```

2. 启动隔离 VS Code。

   ```powershell
   .\start-deepseek-vscode.bat
   ```

3. 在新打开的 VS Code 中使用 Codex 面板。

启动脚本默认会完成：

- 生成隔离 Codex 配置。
- 同步主 Codex 的插件 / MCP 相关配置块。
- 刷新常驻上下文。
- 启动本地 DeepSeek 代理。
- 打开隔离 VS Code 窗口。

### 聊天框指令

在 Codex 聊天框输入：

```text
/D-help
```

可用指令：

```text
/D-switch          切换 Pro / Flash
/D-switch pro      切换到 DeepSeek V4 Pro
/D-switch flash    切换到 DeepSeek V4 Flash
/D-model           查看当前模型
/D-context         查看常驻上下文状态
```

这些指令由本地 DeepSeek 代理处理，不需要手动改配置文件。

### 常驻上下文

常驻上下文默认开启。它不是一次性问答，而是给 DeepSeek Codex 的每轮请求提供项目背景。

默认扫描：

```text
README.md
src
scripts
vscode-extension
```

生成：

```text
.deepseek/resident-context.md
```

这个文件不会提交到仓库。需要扩大或缩小范围时，可以调整启动参数：

```powershell
.\start-deepseek-vscode.bat -ResidentContextPath README.md,src,scripts
```

关闭自动刷新：

```powershell
.\start-deepseek-vscode.bat -SkipResidentContext
```

### 网络代理

如果访问 DeepSeek 需要走独立代理：

```powershell
.\start-deepseek-vscode.bat -DeepSeekProxyUrl http://127.0.0.1:7890
```

这个代理只用于 DeepSeek 上游请求，不影响正常 GPT / Codex 环境。

### 本地 CLI

只想用本地 Codex CLI 时：

```powershell
.\start-deepseek-cli.bat
```

CLI 和 VS Code 共用同一套隔离配置、代理和常驻上下文。

### VS Code 命令面板

安装本地 launcher extension：

```powershell
.\install-vscode-extension.bat
```

重启 VS Code 后可用：

```text
DeepSeek Codex: Open Isolated Window
DeepSeek Codex: Open Isolated Flash
DeepSeek Codex: Open Isolated Pro
```

### 文件结构

```text
src/deepseek-responses-proxy.mjs      本地 Responses 兼容代理
scripts/start-deepseek-vscode.ps1     主启动脚本
scripts/deepseek-long-context.ps1     常驻上下文生成器
vscode-extension/                     本地 VS Code launcher extension
start-deepseek-vscode.bat             VS Code 一键入口
start-deepseek-cli.bat                CLI 一键入口
install-vscode-extension.bat          安装本地 launcher extension
```

### 能力边界

- 这是兼容桥，不是 Codex 官方原生 DeepSeek provider。
- 原生工作流卡片、diff 卡片和工具事件显示由官方 Codex 扩展控制。
- 插件 / MCP 配置可以同步，但最终可用性以 Codex 面板实际工具列表为准。
- 常驻上下文是项目背景，不替代当前用户明确给出的文件和指令。

---

## English Version

[中文](#中文版)

### What It Solves

The VS Code Codex desktop experience is useful, but third-party model bridges
often run into practical friction:

- Default context may not reach the model reliably.
- Switching models through config files is slow.
- DeepSeek network routing should be separate from the normal GPT path.
- The normal Codex / GPT setup should remain untouched.

This project provides an isolated DeepSeek Codex workspace. It prepares a local
proxy, isolated config, resident context, and the VS Code Codex workflow in one
startup path.

### Why Keep VS Code Codex Desktop

Compared with CLI-only usage, VS Code Codex is better for project work:

- **Linked file windows**: chat, files, diffs, and jumps stay in one workspace.
- **Drag-and-drop context**: files, images, and selections can be sent to Codex.
- **Guided interaction**: Codex task guidance, permissions, and session behavior remain available.
- **Plugin / MCP entry points**: plugin, marketplace, MCP, and connector config blocks are synced from the main Codex config. Final availability depends on what the Codex panel exposes.

### Features

- DeepSeek V4 Pro / Flash.
- Chat commands: `/D-switch`, `/D-model`, `/D-context`, `/D-help`.
- Resident context generated on startup and injected into every request.
- Chinese language following by default.
- Dedicated DeepSeek upstream proxy.
- Isolated VS Code profile.
- Local Codex CLI entrypoint.
- Local VS Code launcher extension installer.

### Quick Start

1. Set the DeepSeek API key.

   ```powershell
   [Environment]::SetEnvironmentVariable("DEEPSEEK_API_KEY", "your-deepseek-api-key", "User")
   ```

2. Launch isolated VS Code.

   ```powershell
   .\start-deepseek-vscode.bat
   ```

3. Use the Codex panel in the new VS Code window.

Startup prepares the isolated Codex config, syncs plugin / MCP config blocks,
refreshes resident context, starts the local proxy, and opens VS Code.

### Chat Commands

Type this in the Codex chat:

```text
/D-help
```

Commands:

```text
/D-switch          Toggle Pro / Flash
/D-switch pro      Switch to DeepSeek V4 Pro
/D-switch flash    Switch to DeepSeek V4 Flash
/D-model           Show the active model
/D-context         Show resident context status
```

### Resident Context

Resident context is enabled by default. It provides project background to every
DeepSeek Codex request.

Default inputs:

```text
README.md
src
scripts
vscode-extension
```

Generated file:

```text
.deepseek/resident-context.md
```

Customize the scope:

```powershell
.\start-deepseek-vscode.bat -ResidentContextPath README.md,src,scripts
```

Disable refresh:

```powershell
.\start-deepseek-vscode.bat -SkipResidentContext
```

### Network Proxy

Use a dedicated upstream proxy for DeepSeek:

```powershell
.\start-deepseek-vscode.bat -DeepSeekProxyUrl http://127.0.0.1:7890
```

This only affects DeepSeek upstream requests.

### Local CLI

```powershell
.\start-deepseek-cli.bat
```

CLI and VS Code share the same isolated config, proxy, and resident context.

### VS Code Command Palette

Install the local launcher extension:

```powershell
.\install-vscode-extension.bat
```

Available commands:

```text
DeepSeek Codex: Open Isolated Window
DeepSeek Codex: Open Isolated Flash
DeepSeek Codex: Open Isolated Pro
```

### Project Layout

```text
src/deepseek-responses-proxy.mjs      Local Responses-compatible proxy
scripts/start-deepseek-vscode.ps1     Main startup script
scripts/deepseek-long-context.ps1     Resident context builder
vscode-extension/                     Local VS Code launcher extension
start-deepseek-vscode.bat             VS Code entrypoint
start-deepseek-cli.bat                CLI entrypoint
install-vscode-extension.bat          Launcher extension installer
```

### Limits

- This is a compatibility bridge, not a native Codex DeepSeek provider.
- Native workflow cards, diff cards, and tool event rendering are controlled by the official Codex extension.
- Plugin / MCP config can be synced, but final tool availability depends on the Codex panel.
- Resident context is project background; explicit user instructions and attached files still take priority.
