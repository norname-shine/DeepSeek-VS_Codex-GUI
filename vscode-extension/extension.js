const fs = require("fs");
const path = require("path");
const vscode = require("vscode");

function findLauncherRoot() {
  const workspaceFolders = vscode.workspace.workspaceFolders || [];
  for (const folder of workspaceFolders) {
    const candidate = folder.uri.fsPath;
    if (hasLauncher(candidate)) {
      return candidate;
    }
  }

  const configured = vscode.workspace
    .getConfiguration("deepseekCodexLauncher")
    .get("root");
  if (configured && hasLauncher(configured)) {
    return configured;
  }

  return configured || "";
}

function getDeepSeekProxyUrl() {
  return String(
    vscode.workspace
      .getConfiguration("deepseekCodexLauncher")
      .get("deepSeekProxyUrl") || "",
  ).trim();
}

function hasLauncher(root) {
  return fs.existsSync(path.join(root, "scripts", "start-deepseek-vscode.ps1"));
}

function quotePowerShell(value) {
  return `"${String(value).replace(/`/g, "``").replace(/"/g, '`"')}"`;
}

async function runScript(profile, scriptName, terminalName) {
  const root = findLauncherRoot();
  const script = path.join(root, "scripts", scriptName);

  if (!root || !fs.existsSync(script)) {
    const action = "Open Settings";
    const selected = await vscode.window.showErrorMessage(
      `Isolated DeepSeek VS Code launcher script was not found. Configure deepseekCodexLauncher.root.`,
      action,
    );
    if (selected === action) {
      await vscode.commands.executeCommand(
        "workbench.action.openSettings",
        "deepseekCodexLauncher.root",
      );
    }
    return;
  }

  const terminal = vscode.window.createTerminal({
    name: terminalName,
    cwd: root,
    shellPath: "powershell.exe",
  });

  const command = [
    "powershell.exe",
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    quotePowerShell(script),
    "-Model",
    profile,
  ];

  const deepSeekProxyUrl = getDeepSeekProxyUrl();
  if (deepSeekProxyUrl) {
    command.push("-DeepSeekProxyUrl", quotePowerShell(deepSeekProxyUrl));
  }

  terminal.show();
  terminal.sendText(command.join(" "));
}

async function launch(profile) {
  await runScript(profile, "start-deepseek-vscode.ps1", `DeepSeek VS Code ${profile.replace("deepseek-", "")}`);
}

async function pickAndLaunch() {
  const picked = await vscode.window.showQuickPick(
    [
      {
        label: "DeepSeek V4 Flash",
        description: "deepseek-v4-flash",
        profile: "deepseek-flash",
      },
      {
        label: "DeepSeek V4 Pro",
        description: "deepseek-v4-pro",
        profile: "deepseek-pro",
      },
    ],
    { placeHolder: "Select a DeepSeek model for Codex" },
  );

  if (picked) {
    await launch(picked.profile);
  }
}

function activate(context) {
  context.subscriptions.push(
    vscode.commands.registerCommand("deepseekCodex.pickAndLaunch", pickAndLaunch),
    vscode.commands.registerCommand("deepseekCodex.launchFlash", () => launch("deepseek-flash")),
    vscode.commands.registerCommand("deepseekCodex.launchPro", () => launch("deepseek-pro")),
  );
}

function deactivate() {}

module.exports = { activate, deactivate };
