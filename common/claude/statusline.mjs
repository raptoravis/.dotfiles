import { existsSync, readdirSync, openSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { spawnSync, spawn } from "node:child_process";
import { ReadStream } from "node:tty";

const claudeDir = process.env.CLAUDE_CONFIG_DIR || join(homedir(), ".claude");
const cacheRoot = join(claudeDir, "plugins", "cache");

// --- External usage snapshot (cc-switch fallback) -------------------------
// When cc-switch injects ANTHROPIC_AUTH_TOKEN into settings.json, Claude Code
// stops sending stdin.rate_limits, so claude-hud's 5h / weekly reset bars
// vanish. In that mode we keep a self-refreshed snapshot (see
// claude-hud-usage-refresh.mjs) and feed it to the HUD via main()'s
// getUsageFromExternalSnapshot override. Native subscription logins (no token
// in env) keep using stdin.rate_limits and skip all of this entirely.
const usingInjectedToken = !!(
  process.env.ANTHROPIC_AUTH_TOKEN || process.env.ANTHROPIC_API_KEY
);
const snapshotPath = join(claudeDir, "plugins", "claude-hud", ".external-usage.json");
const SNAPSHOT_REFRESH_MS = 240_000; // re-poll the usage API if older than 4m
const SNAPSHOT_FRESH_MS = 1_800_000; // still render last good value for 30m

function snapshotAgeMs() {
  try {
    return Date.now() - statSync(snapshotPath).mtimeMs;
  } catch {
    return Infinity; // missing
  }
}

function maybeRefreshSnapshot() {
  if (snapshotAgeMs() <= SNAPSHOT_REFRESH_MS) return;
  try {
    const refresher = join(claudeDir, "claude-hud-usage-refresh.mjs");
    if (!existsSync(refresher)) return;
    spawn(process.execPath, [refresher], {
      detached: true,
      stdio: "ignore",
      windowsHide: true,
    }).unref();
  } catch {}
}

// Reads our snapshot and returns the shape claude-hud's usage pipeline expects.
function readSnapshotUsage() {
  try {
    const snap = JSON.parse(readFileSync(snapshotPath, "utf8"));
    if (typeof snap.updatedAt !== "number") return null;
    if (Date.now() - snap.updatedAt > SNAPSHOT_FRESH_MS) return null;
    const fiveHour = snap.fiveHour?.pct ?? null;
    const sevenDay = snap.sevenDay?.pct ?? null;
    if (fiveHour === null && sevenDay === null) return null;
    const toDate = (ms) => (typeof ms === "number" && ms > 0 ? new Date(ms) : null);
    return {
      fiveHour,
      sevenDay,
      fiveHourResetAt: toDate(snap.fiveHour?.resetAt),
      sevenDayResetAt: toDate(snap.sevenDay?.resetAt),
    };
  } catch {
    return null;
  }
}

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

if (usingInjectedToken) maybeRefreshSnapshot();

try {
  const mod = await import(pathToFileURL(indexPath).href);
  if (typeof mod.main === "function") {
    // Only override usage sourcing in injected-token mode; otherwise let the
    // HUD use stdin.rate_limits exactly as upstream intends.
    const overrides = usingInjectedToken
      ? { getUsageFromExternalSnapshot: () => readSnapshotUsage() }
      : {};
    await mod.main(overrides);
  }
} catch (err) {
  process.stderr.write(`claude-hud launcher error: ${err?.message || err}\n`);
  process.exit(0);
}
