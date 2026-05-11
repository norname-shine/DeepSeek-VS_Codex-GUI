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

function hasLauncher(root) {
  return fs.existsSync(path.join(root, "scripts", "start-deepseek-codex.ps1"));
}

function quotePowerShell(value) {
  return `"${String(value).replace(/`/g, "``").replace(/"/g, '`"')}"`;
}

async function launch(profile) {
  const root = findLauncherRoot();
  const script = path.join(root, "scripts", "start-deepseek-codex.ps1");

  if (!root || !fs.existsSync(script)) {
    const action = "Open Settings";
    const selected = await vscode.window.showErrorMessage(
      `DeepSeek Codex launcher script was not found. Configure deepseekCodexLauncher.root.`,
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
    name: `DeepSeek Codex ${profile.replace("deepseek-", "")}`,
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
    "-CodexProfile",
    profile,
  ].join(" ");

  terminal.show();
  terminal.sendText(command);
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
