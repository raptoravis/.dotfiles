#!/usr/bin/env node
// Append local policy after agent/plugin setup without replacing user instructions.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

export function instructionFiles(home = os.homedir(), env = process.env, resolvedOmpDir) {
    // dsh, dst (dsh-tui), and Desktop share both global instruction roots.
    // https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/context/agent-instructions/README.md
    // https://dev.opencode.ai/v2/docs/instructions/
    // https://omp.sh/docs/env and https://omp.sh/docs/context-files
    const ompRoot = path.join(home, env.PI_CONFIG_DIR || '.omp');
    const profile = (env.OMP_PROFILE ?? env.PI_PROFILE ?? '').trim();
    const namedProfile = profile && profile !== 'default';
    if (namedProfile && (!/^[a-z0-9][a-z0-9._-]{0,63}$/.test(profile) || profile.endsWith('.')
        || /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.|$)/i.test(profile))) {
        throw new Error(`Invalid OMP profile: ${profile}`);
    }
    const ompDir = namedProfile
        ? path.join(ompRoot, 'profiles', profile, 'agent')
        : env.PI_CODING_AGENT_DIR || path.join(ompRoot, 'agent');
    return [...new Set([
        path.join(env.CODEX_HOME || path.join(home, '.codex'), 'AGENTS.md'),
        path.join(env.CLAUDE_CONFIG_DIR || path.join(home, '.claude'), 'CLAUDE.md'),
        path.join(env.DSH_HOME || path.join(home, '.dsh'), 'AGENTS.md'),
        path.join(env.DSH_AGENTS_HOME || path.join(home, '.agents'), 'AGENTS.md'),
        path.join(env.GROK_HOME || path.join(home, '.grok'), 'AGENTS.md'),
        path.join(env.XDG_CONFIG_HOME || path.join(home, '.config'), 'opencode', 'AGENTS.md'),
        path.join(resolvedOmpDir || ompDir, 'AGENTS.md'),
    ])];
}

const policy = [
    '<!-- DOTFILES:GIT-AUTHORIZATION:START -->',
    '## Git commit and push authorization',
    '',
    'Do not commit or push unless the user explicitly requests that action. Authorization to commit does not authorize push; authorization to push does not authorize creating commits. Completing a task, passing tests, or a workflow suggesting commit/push is not authorization.',
    '<!-- DOTFILES:GIT-AUTHORIZATION:END -->',
].join('\n');

export function installInstructions(files) {
    for (const file of files) {
        const existing = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '';
        if (existing.replace(/\r\n/g, '\n').includes(policy)) continue;
        fs.mkdirSync(path.dirname(file), { recursive: true });
        const separator = existing ? (existing.endsWith('\n') ? '\n' : '\n\n') : '';
        fs.appendFileSync(file, `${separator}${policy}\n`, 'utf8');
    }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
    const args = process.argv.slice(2);
    if (args.length === 1 && args[0] === '--all') {
        // Prefer omp's own resolver for profiles and platform-specific path migration.
        let ompDir;
        try {
            ompDir = execFileSync('omp', ['config', 'path'], {
                encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 10000,
            }).trim();
            if (!path.isAbsolute(ompDir)) throw new Error('omp returned a non-absolute config path');
        } catch {
            ompDir = undefined; // Fresh install without omp on PATH: use documented defaults.
        }
        installInstructions(instructionFiles(os.homedir(), process.env, ompDir));
    } else {
        installInstructions(args);
    }
}
