import { existsSync, readdirSync, openSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";
import { ReadStream } from "node:tty";

const claudeDir = process.env.CLAUDE_CONFIG_DIR || join(homedir(), ".claude");
const cacheRoot = join(claudeDir, "plugins", "cache");

function safeList(dir) {
  try {
    return readdirSync(dir);
  } catch {
    return [];
  }
}

function findLatestIndex() {
  let best = null;
  let bestKey = "";
  for (const marketplace of safeList(cacheRoot)) {
    const pluginDir = join(cacheRoot, marketplace, "claude-hud");
    if (!existsSync(pluginDir)) continue;
    for (const version of safeList(pluginDir)) {
      if (!/^\d+(\.\d+)+$/.test(version)) continue;
      const indexPath = join(pluginDir, version, "dist", "index.js");
      if (!existsSync(indexPath)) continue;
      const key = version.split(".").map((p) => p.padStart(8, "0")).join(".");
      if (key > bestKey) {
        bestKey = key;
        best = indexPath;
      }
    }
  }
  return best;
}

function detectColumns() {
  if (process.stderr.columns > 0) return process.stderr.columns;
  if (process.stdout.columns > 0) return process.stdout.columns;
  if (process.platform !== "win32") {
    try {
      const fd = openSync("/dev/tty", "r");
      const stream = new ReadStream(fd);
      const c = stream.columns;
      stream.destroy();
      if (c > 0) return c;
    } catch {}
  } else {
    try {
      const r = spawnSync(
        "powershell",
        ["-NoProfile", "-Command", "[Console]::WindowWidth"],
        { encoding: "utf8", timeout: 2000 },
      );
      const c = parseInt((r.stdout || "").trim(), 10);
      if (c > 0) return c;
    } catch {}
  }
  return 120;
}

const indexPath = findLatestIndex();
if (!indexPath) process.exit(0);

const cols = detectColumns();
process.env.COLUMNS = String(Math.max(1, cols - 4));

try {
  const mod = await import(pathToFileURL(indexPath).href);
  if (typeof mod.main === "function") await mod.main();
} catch (err) {
  process.stderr.write(`claude-hud launcher error: ${err?.message || err}\n`);
  process.exit(0);
}
