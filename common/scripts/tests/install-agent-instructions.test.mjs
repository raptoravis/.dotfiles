import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { instructionFiles, installInstructions } from '../install-agent-instructions.mjs';

const script = fileURLToPath(new URL('../install-agent-instructions.mjs', import.meta.url));

test('creates global instructions, preserves existing content, and is idempotent', () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-instructions-'));
    try {
        const agents = path.join(root, 'custom codex', 'AGENTS.md');
        const claude = path.join(root, 'custom claude', 'CLAUDE.md');
        fs.mkdirSync(path.dirname(claude), { recursive: true });
        const original = '\uFEFF# Existing instructions\r\nKeep this content without a trailing newline.';
        fs.writeFileSync(claude, original);
        const run = () => execFileSync(process.execPath, [script, agents, claude]);
        run();
        const first = [agents, claude].map(file => fs.readFileSync(file, 'utf8'));
        assert.ok(first[1].startsWith(`${original}\n\n`));
        for (const content of first) {
            assert.match(content, /Do not commit or push unless the user explicitly requests that action/);
            assert.match(content, /Authorization to commit does not authorize push/);
            assert.match(content, /authorization to push does not authorize creating commits/);
        }
        run();
        assert.deepEqual([agents, claude].map(file => fs.readFileSync(file, 'utf8')), first);
        fs.writeFileSync(agents, first[0].replace(/\n/g, '\r\n'));
        const crlf = fs.readFileSync(agents, 'utf8');
        run();
        assert.equal(fs.readFileSync(agents, 'utf8'), crlf);
    } finally {
        fs.rmSync(root, { recursive: true, force: true });
    }
});

test('all installed agents get policy in their default global files', () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'all-agent-instructions-'));
    try {
        const files = instructionFiles(root, {});
        assert.deepEqual(files.map(file => path.relative(root, file).split(path.sep).join('/')), [
            '.codex/AGENTS.md', '.claude/CLAUDE.md', '.dsh/AGENTS.md', '.agents/AGENTS.md',
            '.grok/AGENTS.md', '.config/opencode/AGENTS.md', '.omp/agent/AGENTS.md',
        ]);
        installInstructions(files);
        const contents = files.map(file => fs.readFileSync(file, 'utf8'));
        assert.equal(new Set(contents).size, 1);
        installInstructions(files);
        assert.deepEqual(files.map(file => fs.readFileSync(file, 'utf8')), contents);
    } finally {
        fs.rmSync(root, { recursive: true, force: true });
    }
});

test('respects custom roots and OMP profile precedence', () => {
    const home = path.resolve('test-home');
    const env = Object.fromEntries([
        'CODEX_HOME', 'CLAUDE_CONFIG_DIR', 'DSH_HOME', 'DSH_AGENTS_HOME', 'GROK_HOME',
        'XDG_CONFIG_HOME', 'PI_CODING_AGENT_DIR',
    ].map(key => [key, path.join(home, key)]));
    const files = instructionFiles(home, env);
    assert.deepEqual(files, [
        path.join(env.CODEX_HOME, 'AGENTS.md'), path.join(env.CLAUDE_CONFIG_DIR, 'CLAUDE.md'),
        path.join(env.DSH_HOME, 'AGENTS.md'), path.join(env.DSH_AGENTS_HOME, 'AGENTS.md'),
        path.join(env.GROK_HOME, 'AGENTS.md'), path.join(env.XDG_CONFIG_HOME, 'opencode', 'AGENTS.md'),
        path.join(env.PI_CODING_AGENT_DIR, 'AGENTS.md'),
    ]);
    const named = { ...env, PI_CONFIG_DIR: '.custom-omp', OMP_PROFILE: 'work', PI_PROFILE: 'legacy' };
    assert.equal(instructionFiles(home, named).at(-1), path.join(home, '.custom-omp/profiles/work/agent/AGENTS.md'));
    assert.equal(instructionFiles(home, { ...named, OMP_PROFILE: '' }).at(-1), files.at(-1));
    assert.equal(instructionFiles(home, { ...named, OMP_PROFILE: undefined }).at(-1),
        path.join(home, '.custom-omp/profiles/legacy/agent/AGENTS.md'));
    assert.throws(() => instructionFiles(home, { OMP_PROFILE: '../outside' }), /Invalid OMP profile/);
    const runtimeDir = path.join(home, 'runtime-resolved-omp');
    assert.equal(instructionFiles(home, env, runtimeDir).at(-1), path.join(runtimeDir, 'AGENTS.md'));
});
