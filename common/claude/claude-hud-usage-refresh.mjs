// claude-hud usage snapshot refresher.
//
// Why: claude-hud >=0.0.12 shows the 5h / weekly reset bars ONLY from Claude
// Code's stdin `rate_limits`. When cc-switch injects ANTHROPIC_AUTH_TOKEN into
// ~/.claude/settings.json, Claude Code stops emitting rate_limits, so the bars
// vanish. claude-hud still supports an external usage snapshot fallback, so we
// poll Anthropic's OAuth usage API ourselves (using the subscription OAuth
// token Claude Code already stored) and write a snapshot the HUD can read.
//
// Invoked detached by statusline.mjs when the snapshot is stale. Reads nothing
// from the network unless OAuth credentials exist. Fails silently — a missing
// or stale snapshot just means the usage bars don't render, never an error.

import { readFileSync, writeFileSync, renameSync, existsSync, statSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join, dirname } from "node:path";
import { request } from "node:https";

const MIN_REFRESH_MS = 90_000; // skip if snapshot was written < 90s ago
const API_TIMEOUT_MS = 15_000;

const claudeDir = process.env.CLAUDE_CONFIG_DIR || join(homedir(), ".claude");
const snapshotPath = join(claudeDir, "plugins", "claude-hud", ".external-usage.json");

// Self-throttle: another render may have just refreshed it.
try {
  if (existsSync(snapshotPath) && Date.now() - statSync(snapshotPath).mtimeMs < MIN_REFRESH_MS) {
    process.exit(0);
  }
} catch {}

function readToken() {
  // cc-switch injects the active account's token into the environment, so
  // prefer it — that's the CURRENT user. Falling back to ~/.claude's stored
  // OAuth credential would poll a stale (possibly previous) account, or simply
  // not exist on Windows where Claude Code keeps no .credentials.json file.
  const envToken = process.env.ANTHROPIC_AUTH_TOKEN || process.env.ANTHROPIC_API_KEY;
  if (typeof envToken === "string" && envToken.trim()) return envToken.trim();
  try {
    const raw = readFileSync(join(claudeDir, ".credentials.json"), "utf8");
    const oauth = JSON.parse(raw)?.claudeAiOauth;
    const token = oauth?.accessToken;
    return typeof token === "string" && token.trim() ? token.trim() : null;
  } catch {
    return null;
  }
}

function writeSnapshot(snapshot) {
  try {
    mkdirSync(dirname(snapshotPath), { recursive: true });
    const tmp = `${snapshotPath}.tmp`;
    writeFileSync(tmp, JSON.stringify(snapshot), "utf8");
    renameSync(tmp, snapshotPath); // atomic
  } catch {}
}

// Overwrite whatever's on disk with an explicit "no data" snapshot. The HUD's
// readSnapshotUsage treats all-null as no data and hides the bars, so this
// clears a previous account's stale value instead of leaving it on screen.
// The fresh mtime also throttles the next refresh — we don't re-hit the API
// every render just because there's nothing to show.
function writeUnavailable() {
  writeSnapshot({
    updatedAt: Date.now(),
    fiveHour: { pct: null, resetAt: null },
    sevenDay: { pct: null, resetAt: null },
  });
}

// API resets_at may be an ISO string or epoch (s or ms); normalize to epoch ms.
function toEpochMs(value) {
  if (typeof value === "number" && Number.isFinite(value) && value > 0) {
    return value > 1e12 ? value : value * 1000;
  }
  if (typeof value === "string" && value.trim()) {
    const ms = new Date(value).getTime();
    return Number.isNaN(ms) ? null : ms;
  }
  return null;
}

function toPct(value) {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  return Math.round(Math.min(100, Math.max(0, value)));
}

function fetchUsage(token) {
  return new Promise((resolve) => {
    const req = request(
      {
        hostname: "api.anthropic.com",
        path: "/api/oauth/usage",
        method: "GET",
        headers: {
          Authorization: `Bearer ${token}`,
          "anthropic-beta": "oauth-2025-04-20",
          "User-Agent": "claude-code/2.1",
        },
        timeout: API_TIMEOUT_MS,
      },
      (res) => {
        let data = "";
        res.on("data", (c) => (data += c));
        res.on("end", () => {
          if (res.statusCode !== 200) return resolve({ ok: false, status: res.statusCode });
          try {
            resolve({ ok: true, status: 200, json: JSON.parse(data) });
          } catch {
            resolve({ ok: false, status: 200 });
          }
        });
      },
    );
    req.on("error", () => resolve(null));
    req.on("timeout", () => {
      req.destroy();
      resolve(null);
    });
    req.end();
  });
}

const token = readToken();
if (!token) {
  writeUnavailable();
  process.exit(0);
}

const res = await fetchUsage(token);
if (res === null) process.exit(0); // transient network error — keep last good snapshot

if (!res.ok) {
  // 401/403 = the token is rejected or lacks the usage scope (a cc-switch
  // token-injected account carries user:inference but not user:profile, which
  // /api/oauth/usage requires). That's definitive, so clear the stale value.
  // Other status codes may be transient server hiccups — leave the snapshot.
  if (res.status === 401 || res.status === 403) writeUnavailable();
  process.exit(0);
}

const api = res.json;
const snapshot = {
  updatedAt: Date.now(),
  fiveHour: { pct: toPct(api.five_hour?.utilization), resetAt: toEpochMs(api.five_hour?.resets_at) },
  sevenDay: { pct: toPct(api.seven_day?.utilization), resetAt: toEpochMs(api.seven_day?.resets_at) },
};

if (snapshot.fiveHour.pct === null && snapshot.sevenDay.pct === null) {
  writeUnavailable();
  process.exit(0);
}

writeSnapshot(snapshot);
