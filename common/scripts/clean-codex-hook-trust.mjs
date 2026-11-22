#!/usr/bin/env node
// Remove [hooks.state] entries that `omx setup` cannot safely reconcile:
// foreign hook files and legacy native-hook entries carrying metadata such as
// `enabled`. OMX owns <CODEX_HOME>/hooks.json trust and emits one trusted_hash
// per entry; stale metadata or duplicate path spellings make its conservative
// refresh refuse to overwrite the state. Back up before writing and leave valid
// native trusted_hash-only entries for OMX to verify or replace.
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

for (let index = 0; index < lines.length;) {
    const trimmed = lines[index].trim();
    if (!trimmed.startsWith('[hooks.state.')) {
        kept.push(lines[index]);
        index += 1;
        continue;
    }

    let end = index + 1;
    while (end < lines.length && !lines[end].trim().startsWith('[')) end += 1;
    const block = lines.slice(index, end);
    const isNative = norm(trimmed).includes(nativeHooks);
    const hasLegacyMetadata = block.slice(1).some((line) => {
        const assignment = line.trim().match(/^([A-Za-z0-9_-]+)\s*=/);
        return assignment && assignment[1] !== 'trusted_hash';
    });

    if (!isNative || hasLegacyMetadata) removed.push(trimmed);
    else kept.push(...block);
    index = end;
}

if (removed.length === 0) process.exit(0);

const stamp = new Date().toISOString().replace(/[:.]/g, '-');
const bakPath = `${cfgPath}.bak-${stamp}`;
fs.copyFileSync(cfgPath, bakPath);
fs.writeFileSync(cfgPath, kept.join(newline), 'utf8');

console.log(`removed ${removed.length} conflicting [hooks.state] entries from ${cfgPath} (backup: ${bakPath})`);
