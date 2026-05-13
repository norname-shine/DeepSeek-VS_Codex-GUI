import net from "node:net";
import crypto from "node:crypto";

const port = Number(process.argv[2] || process.env.CODEX_PLUGIN_UNLOCK_PORT || 9333);
const host = "127.0.0.1";
const timeoutMs = Number(process.argv[3] || 90000);

const payload = String.raw`
(() => {
  if (window.__deepseekCodexPluginUnlockInstalled) return;
  window.__deepseekCodexPluginUnlockInstalled = true;

  const selectors = {
    disabledInstallButton: 'button:disabled.w-full.justify-center, [role="button"][aria-disabled="true"].cursor-not-allowed',
    pluginNavButton: 'nav[role="navigation"] button.h-token-nav-row.w-full',
    pluginSvgPath: 'svg path[d^="M7.94562 14.0277"]',
  };

  function reactFiberFrom(element) {
    const fiberKey = Object.keys(element).find((key) => key.startsWith("__reactFiber") || key.startsWith("__reactInternalInstance"));
    return fiberKey ? element[fiberKey] : null;
  }

  function authContextValueFrom(element) {
    for (let fiber = reactFiberFrom(element); fiber; fiber = fiber.return) {
      for (const value of [fiber.memoizedProps?.value, fiber.pendingProps?.value]) {
        if (value && typeof value === "object" && typeof value.setAuthMethod === "function" && "authMethod" in value) {
          return value;
        }
      }
    }
    return null;
  }

  function spoofChatGPTAuthMethod(element) {
    const auth = authContextValueFrom(element);
    if (!auth || auth.authMethod === "chatgpt") return false;
    auth.setAuthMethod("chatgpt");
    return true;
  }

  function pluginEntryButton() {
    const byIcon = document.querySelector(selectors.pluginNavButton + " " + selectors.pluginSvgPath)?.closest("button");
    if (byIcon) return byIcon;
    return Array.from(document.querySelectorAll(selectors.pluginNavButton))
      .find((button) => /^(插件|Plugins)(\s+-\s+.*)?$/i.test((button.textContent || "").trim())) || null;
  }

  function enablePluginEntry() {
    const pluginButton = pluginEntryButton();
    if (!pluginButton) return;
    spoofChatGPTAuthMethod(pluginButton);
    pluginButton.disabled = false;
    pluginButton.removeAttribute("disabled");
    pluginButton.style.display = "";
    pluginButton.querySelectorAll("*").forEach((node) => {
      node.style.display = "";
    });
    const reactPropsKey = Object.keys(pluginButton).find((key) => key.startsWith("__reactProps"));
    if (reactPropsKey) {
      pluginButton[reactPropsKey].disabled = false;
    }
    if (pluginButton.dataset.deepseekPluginUnlock === "true") return;
    pluginButton.dataset.deepseekPluginUnlock = "true";
    pluginButton.addEventListener("click", () => spoofChatGPTAuthMethod(pluginButton), true);
  }

  function unblockButtonElement(button) {
    button.disabled = false;
    button.removeAttribute("disabled");
    button.removeAttribute("aria-disabled");
    button.classList.remove("disabled", "opacity-50", "cursor-not-allowed", "pointer-events-none");
    button.style.pointerEvents = "auto";
    button.tabIndex = 0;
    const reactPropsKey = Object.keys(button).find((key) => key.startsWith("__reactProps"));
    if (reactPropsKey) {
      button[reactPropsKey].disabled = false;
      button[reactPropsKey]["aria-disabled"] = false;
    }
  }

  function unblockPluginInstallButtons() {
    Array.from(document.querySelectorAll(selectors.disabledInstallButton)).forEach((button) => {
      const text = (button.textContent || "").trim();
      if (!/^安装\s/.test(text) && !/^Install\s/.test(text) && text !== "强制安装") return;
      unblockButtonElement(button);
    });
  }

  function tick() {
    enablePluginEntry();
    unblockPluginInstallButtons();
  }

  tick();
  setInterval(tick, 800);
})();
`;

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function listTargets() {
  const response = await fetch(`http://${host}:${port}/json/list`);
  if (!response.ok) throw new Error(`CDP target list returned ${response.status}`);
  return await response.json();
}

function encodeFrame(text) {
  const payloadBuffer = Buffer.from(text);
  const length = payloadBuffer.length;
  let headerLength = 2;
  if (length >= 126 && length < 65536) headerLength += 2;
  else if (length >= 65536) headerLength += 8;
  const frame = Buffer.alloc(headerLength + 4 + length);
  frame[0] = 0x81;
  if (length < 126) {
    frame[1] = 0x80 | length;
  } else if (length < 65536) {
    frame[1] = 0x80 | 126;
    frame.writeUInt16BE(length, 2);
  } else {
    frame[1] = 0x80 | 127;
    frame.writeBigUInt64BE(BigInt(length), 2);
  }
  const maskOffset = headerLength;
  const mask = crypto.randomBytes(4);
  mask.copy(frame, maskOffset);
  for (let i = 0; i < length; i += 1) {
    frame[maskOffset + 4 + i] = payloadBuffer[i] ^ mask[i % 4];
  }
  return frame;
}

function sendRuntimeEvaluate(wsUrl) {
  return new Promise((resolve, reject) => {
    const url = new URL(wsUrl);
    const key = crypto.randomBytes(16).toString("base64");
    const socket = net.createConnection({ host: url.hostname, port: Number(url.port) }, () => {
      socket.write([
        `GET ${url.pathname}${url.search} HTTP/1.1`,
        `Host: ${url.host}`,
        "Upgrade: websocket",
        "Connection: Upgrade",
        `Sec-WebSocket-Key: ${key}`,
        "Sec-WebSocket-Version: 13",
        "",
        "",
      ].join("\r\n"));
    });

    let upgraded = false;
    let buffer = Buffer.alloc(0);
    const timer = setTimeout(() => {
      socket.destroy();
      reject(new Error("CDP websocket timeout"));
    }, 3000);

    socket.on("data", (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      if (!upgraded && buffer.includes(Buffer.from("\r\n\r\n"))) {
        const header = buffer.toString("utf8", 0, buffer.indexOf("\r\n\r\n"));
        if (!header.includes("101")) {
          clearTimeout(timer);
          socket.destroy();
          reject(new Error("CDP websocket upgrade failed"));
          return;
        }
        upgraded = true;
        const message = JSON.stringify({
          id: 1,
          method: "Runtime.evaluate",
          params: {
            expression: payload,
            includeCommandLineAPI: false,
            awaitPromise: false,
          },
        });
        socket.write(encodeFrame(message), () => {
          clearTimeout(timer);
          socket.end();
          resolve();
        });
      }
    });
    socket.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
}

async function main() {
  const startedAt = Date.now();
  const injected = new Set();
  while (Date.now() - startedAt < timeoutMs) {
    try {
      const targets = await listTargets();
      for (const target of targets) {
        if (!target.webSocketDebuggerUrl || injected.has(target.id)) continue;
        const url = `${target.url || ""} ${target.title || ""}`;
        if (!/workbench|webview|chatgpt|codex/i.test(url)) continue;
        await sendRuntimeEvaluate(target.webSocketDebuggerUrl);
        injected.add(target.id);
        console.error(`[codex-plugin-unlock] injected target=${target.id} ${target.type || ""} ${target.title || ""}`);
      }
    } catch {
      // VS Code may still be starting.
    }
    await sleep(1000);
  }
}

main().catch((error) => {
  console.error(`[codex-plugin-unlock] ${error?.message || error}`);
  process.exitCode = 1;
});
