#!/usr/bin/env node
// Remove foreign (non-native) [hooks.state] entries from Codex config.toml so a
// subsequent `omx setup --scope user` can reconcile its hook trust state instead
// of refusing to overwrite trust state it does not own. `codex mcp add` and
// `zg install` re-serialize config.toml and can pull project-local
// `.codex/hooks.json` or legacy `oh-my-codex@*` plugin hook trust into the
// OMX-managed block; omx then declines to replace those entries. We keep only
// omx's native wrapper entries (<CODEX_HOME>/hooks.json:*) and back up before
// writing. No-op when there is nothing foreign to remove.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const codexHome = process.env.CODEX_HOME || path.join(os.homedir(), '.codex');
const cfgPath = path.join(codexHome, 'config.toml');

if (!fs.existsSync(cfgPath)) process.exit(0);

const raw = fs.readFileSync(cfgPath, 'utf8');
const newline = raw.includes('\r\n') ? '\r\n' : '\n';
const lines = raw.split(/\r?\n/);

// Normalize for comparison: forward slashes, lowercase, collapse duplicate slashes.
const norm = (s) => s.replace(/\\/g, '/').toLowerCase().replace(/\/+/g, '/');
const nativeHooks = norm(path.join(codexHome, 'hooks.json'));

const kept = [];
const removed = [];
let skip = false;

for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed.startsWith('[')) {
        // A header line starts (or ends) a block. Skip a [hooks.state] block only
        // when it does not reference the native Codex hooks file.
        skip = trimmed.startsWith('[hooks.state.') && !norm(trimmed).includes(nativeHooks);
        if (skip) removed.push(trimmed);
    }
    if (!skip) kept.push(line);
}

if (removed.length === 0) process.exit(0);

const stamp = new Date().toISOString().replace(/[:.]/g, '-');
const bakPath = `${cfgPath}.bak-${stamp}`;
fs.copyFileSync(cfgPath, bakPath);
fs.writeFileSync(cfgPath, kept.join(newline), 'utf8');

console.log(`removed ${removed.length} foreign [hooks.state] entries from ${cfgPath} (backup: ${bakPath})`);
