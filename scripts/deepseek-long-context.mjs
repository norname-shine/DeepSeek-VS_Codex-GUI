import { spawnSync } from "node:child_process";
import { createWriteStream } from "node:fs";
import { mkdir, readFile, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { fetch as undiciFetch, ProxyAgent } from "undici";

const DEFAULT_EXCLUDES = [
  ".git",
  ".codex-deepseek-vscode",
  ".vscode-deepseek-user-data",
  "node_modules",
];

const TEXT_EXTENSIONS = new Set([
  ".bat",
  ".c",
  ".cpp",
  ".cs",
  ".css",
  ".go",
  ".h",
  ".hpp",
  ".html",
  ".java",
  ".js",
  ".json",
  ".jsx",
  ".md",
  ".mjs",
  ".ps1",
  ".py",
  ".rs",
  ".sh",
  ".sql",
  ".toml",
  ".ts",
  ".tsx",
  ".txt",
  ".xml",
  ".yaml",
  ".yml",
]);

function parseArgs(argv) {
  const options = {
    paths: [],
    model: "deepseek-v4-pro",
    prompt: "Analyze the provided files. Summarize the architecture, key risks, and recommended next steps.",
    promptFile: "",
    output: "",
    maxInputTokens: 900000,
    maxFileBytes: 1000000,
    maxOutputTokens: 8192,
    contextOutput: "",
    dryRun: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = () => {
      i += 1;
      if (i >= argv.length) throw new Error(`Missing value for ${arg}`);
      return argv[i];
    };

    if (arg === "--path") options.paths.push(next());
    else if (arg === "--model") options.model = next();
    else if (arg === "--prompt") options.prompt = next();
    else if (arg === "--prompt-file") options.promptFile = next();
    else if (arg === "--output") options.output = next();
    else if (arg === "--max-input-tokens") options.maxInputTokens = Number(next());
    else if (arg === "--max-file-bytes") options.maxFileBytes = Number(next());
    else if (arg === "--max-output-tokens") options.maxOutputTokens = Number(next());
    else if (arg === "--context-output") options.contextOutput = next();
    else if (arg === "--dry-run") options.dryRun = true;
    else if (arg === "--help" || arg === "-h") {
      printHelp();
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (options.paths.length === 0) options.paths.push(".");
  return options;
}

function printHelp() {
  console.log(`Usage:
  node scripts/deepseek-long-context.mjs --path . --prompt "Analyze this repo"

Options:
  --path <path>                 File or directory to include. Repeatable.
  --prompt <text>               Analysis prompt.
  --prompt-file <file>          Read the prompt from a file.
  --model <model>               deepseek-v4-pro or deepseek-v4-flash.
  --output <file>               Save the answer to a file.
  --max-input-tokens <number>   Approximate input budget. Default 900000.
  --max-file-bytes <number>     Per-file byte cap. Default 1000000.
  --max-output-tokens <number>  Output cap. Default 8192.
  --context-output <file>       Write a resident context corpus file and exit.
  --dry-run                     Collect files and estimate tokens without calling DeepSeek.`);
}

function estimateTokens(text) {
  return Math.ceil(text.length / 4);
}

function normalizePath(filePath) {
  return filePath.replaceAll("\\", "/");
}

function isExcluded(filePath) {
  const normalized = normalizePath(path.relative(process.cwd(), filePath));
  return DEFAULT_EXCLUDES.some((prefix) => normalized === prefix || normalized.startsWith(`${prefix}/`));
}

function isLikelyTextFile(filePath) {
  const ext = path.extname(filePath).toLowerCase();
  if (TEXT_EXTENSIONS.has(ext)) return true;
  const name = path.basename(filePath).toLowerCase();
  return name === "dockerfile" || name === "makefile" || name === ".gitignore";
}

function listFilesWithRg(root) {
  const result = spawnSync("rg", ["--files", root], {
    cwd: process.cwd(),
    encoding: "utf8",
    windowsHide: true,
  });

  if (result.status !== 0 && !result.stdout) {
    return [];
  }

  return result.stdout
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((file) => path.resolve(process.cwd(), file));
}

async function collectFiles(paths, maxFileBytes) {
  const files = [];

  for (const inputPath of paths) {
    const resolved = path.resolve(process.cwd(), inputPath);
    const stats = await stat(resolved);
    if (stats.isDirectory()) {
      files.push(...listFilesWithRg(resolved));
    } else if (stats.isFile()) {
      files.push(resolved);
    }
  }

  const uniqueFiles = [...new Set(files)]
    .filter((file) => !isExcluded(file))
    .filter(isLikelyTextFile)
    .sort((a, b) => normalizePath(a).localeCompare(normalizePath(b)));

  const collected = [];
  for (const file of uniqueFiles) {
    const stats = await stat(file);
    if (!stats.isFile() || stats.size > maxFileBytes) continue;
    const content = await readFile(file, "utf8").catch(() => null);
    if (content === null || content.includes("\u0000")) continue;
    collected.push({
      path: normalizePath(path.relative(process.cwd(), file)),
      content,
      tokens: estimateTokens(content),
    });
  }

  return collected;
}

function buildCorpus(files, maxInputTokens) {
  let tokens = 0;
  const included = [];
  const skipped = [];

  for (const file of files) {
    const wrapperTokens = estimateTokens(`\n\n--- FILE: ${file.path} ---\n`);
    if (tokens + file.tokens + wrapperTokens > maxInputTokens) {
      skipped.push(file.path);
      continue;
    }
    tokens += file.tokens + wrapperTokens;
    included.push(file);
  }

  const corpus = included
    .map((file) => `--- FILE: ${file.path} ---\n${file.content}`)
    .join("\n\n");

  return { corpus, included, skipped, tokens };
}

function buildResidentContext({ prompt, corpus, included, skipped, tokens }) {
  return [
    "# DeepSeek Resident Project Context",
    "",
    "This file is generated by the local DeepSeek long-context tool.",
    "It is supplied as low-priority project background when present.",
    "Codex chat-window messages, attachments, selections, tool results, and the latest user request remain authoritative.",
    "",
    "## Context Prompt",
    "",
    prompt.trim(),
    "",
    "## Corpus Summary",
    "",
    `- Included files: ${included.length}`,
    `- Skipped files due to budget: ${skipped.length}`,
    `- Estimated input tokens: ${tokens}`,
    "",
    "## Included Files",
    "",
    ...included.map((file) => `- ${file.path} (${file.tokens} estimated tokens)`),
    "",
    skipped.length ? "## Skipped Files" : "",
    "",
    ...skipped.map((file) => `- ${file}`),
    "",
    "## File Corpus",
    "",
    corpus,
    "",
  ]
    .filter((line, index, lines) => line || lines[index - 1] !== "")
    .join("\n");
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const prompt = options.promptFile ? await readFile(options.promptFile, "utf8") : options.prompt;
  const files = await collectFiles(options.paths, options.maxFileBytes);
  const { corpus, included, skipped, tokens } = buildCorpus(files, options.maxInputTokens);
  const proxyUrl = (process.env.DEEPSEEK_UPSTREAM_PROXY || process.env.DEEPSEEK_HTTPS_PROXY || "").trim();
  const dispatcher = proxyUrl ? new ProxyAgent(proxyUrl) : undefined;

  const userContent = [
    prompt.trim(),
    "",
    `Included files: ${included.length}`,
    `Skipped files due to budget: ${skipped.length}`,
    `Estimated input tokens: ${tokens}`,
    "",
    corpus,
  ].join("\n");

  console.error(`[deepseek-long-context] model=${options.model}`);
  console.error(`[deepseek-long-context] files=${included.length} skipped=${skipped.length} estimated_tokens=${tokens}`);
  if (proxyUrl) console.error(`[deepseek-long-context] upstream proxy=${proxyUrl}`);

  if (options.dryRun) {
    console.log(JSON.stringify(
      {
        model: options.model,
        files: included.map((file) => ({ path: file.path, estimated_tokens: file.tokens })),
        skipped,
        estimated_input_tokens: tokens,
      },
      null,
      2,
    ));
    return;
  }

  if (options.contextOutput) {
    const outputPath = path.resolve(process.cwd(), options.contextOutput);
    await mkdir(path.dirname(outputPath), { recursive: true });
    await writeFile(outputPath, buildResidentContext({ prompt, corpus, included, skipped, tokens }), "utf8");
    console.error(`[deepseek-long-context] wrote resident context ${outputPath}`);
    return;
  }

  const apiKey = process.env.DEEPSEEK_API_KEY;
  if (!apiKey) throw new Error("Missing DEEPSEEK_API_KEY.");

  const response = await undiciFetch("https://api.deepseek.com/chat/completions", {
    method: "POST",
    headers: {
      authorization: `Bearer ${apiKey}`,
      "content-type": "application/json",
    },
    dispatcher,
    body: JSON.stringify({
      model: options.model,
      messages: [
        {
          role: "system",
          content:
            "You are a senior software architect. Use the provided repository corpus as source material. Be precise, cite file paths, and distinguish evidence from inference.",
        },
        { role: "user", content: userContent },
      ],
      stream: true,
      max_tokens: options.maxOutputTokens,
      thinking: { type: "disabled" },
    }),
  });

  if (!response.ok || !response.body) {
    throw new Error(`DeepSeek API failed ${response.status}: ${await response.text()}`);
  }

  const output = options.output ? createWriteStream(options.output, { encoding: "utf8" }) : null;
  let buffer = "";
  const decoder = new TextDecoder();

  for await (const chunk of response.body) {
    buffer += decoder.decode(chunk, { stream: true });
    const lines = buffer.split(/\r?\n/);
    buffer = lines.pop() || "";

    for (const line of lines) {
      if (!line.startsWith("data:")) continue;
      const raw = line.slice(5).trim();
      if (!raw || raw === "[DONE]") continue;
      const parsed = JSON.parse(raw);
      const delta = parsed.choices?.[0]?.delta?.content || "";
      if (!delta) continue;
      process.stdout.write(delta);
      if (output) output.write(delta);
    }
  }

  if (output) output.end();
  process.stdout.write("\n");
}

main().catch((error) => {
  console.error(`[deepseek-long-context] ${error?.message || error}`);
  process.exit(1);
});
