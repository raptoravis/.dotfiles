// Run with the owning DSH runtime (Electron in Desktop) to resolve its actual peers.
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const control = '@deepseek-ai/dsh-tool-subagent-control';
const begin = '# --- dsh-maoying preset managed (auto-generated; do not edit) ---';
const end = '# --- end dsh-maoying preset managed ---';

export function removeObsoleteRow(text) {
    return text.replace(
        /^([ \t]*)- id: tool-subagent-list-agents\r?\n\1  name: ["']?@deepseek-ai\/dsh-tool-subagent-control\/list-agents["']?\r?\n/gm,
        (row, indent, offset) => {
            const next = text.slice(offset + row.length).split(/\r?\n/)
                .find(line => line.trim() && !line.trimStart().startsWith('#'));
            if (next && next.match(/^[ \t]*/)[0].length > indent.length) {
                throw new Error('Obsolete list-agents row has unexpected fields; refusing to change it');
            }
            return '';
        },
    );
}

function repairManagedBlocks(text) {
    // Never remove a similarly named plugin from user-owned configuration.
    let block = null;
    let output = '';
    for (const line of text.match(/[^\n]*\n|[^\n]+$/g) || []) {
        const marker = line.replace(/\r?\n$/, '').replace(/^\uFEFF/, '');
        if (marker === begin) {
            if (block !== null) throw new Error('Nested Maoying managed block; refusing to change it');
            block = line;
        } else if (marker === end) {
            if (block === null) throw new Error('Misordered Maoying managed block; refusing to change it');
            output += removeObsoleteRow(block + line);
            block = null;
        } else if (block !== null) {
            block += line;
        } else {
            output += line;
        }
    }
    if (block !== null) throw new Error('Incomplete Maoying managed block; refusing to change it');
    return output;
}

export function repairMaoying({ hostRoot, home, profile }) {
    if (!/^[\w.-]+$/.test(profile) || profile === '.' || profile === '..') {
        throw new Error('Invalid DSH profile name');
    }
    const profileDir = path.join(home, 'profiles', profile);
    const packageDir = path.join(profileDir, 'node_modules', 'dsh-maoying');
    if (!fs.existsSync(path.join(packageDir, 'package.json'))) return [];
    const require = createRequire(path.resolve(hostRoot, 'package.json'));
    try {
        require.resolve(`${control}/list-agents`);
        return []; // Older hosts still need this separately registered tool.
    } catch (error) {
        if (!['ERR_PACKAGE_PATH_NOT_EXPORTED', 'MODULE_NOT_FOUND'].includes(error.code)) throw error;
    }
    const main = fs.readFileSync(require.resolve(control), 'utf8')
        .replace(/\/\*[\s\S]*?\*\/|^\s*\/\/.*$/gm, '');
    if (!/\bname\s*:\s*["']list_agents["']/.test(main)) {
        throw new Error('Host control plugin does not visibly provide list_agents; leaving Maoying unchanged');
    }
    const candidates = [
        ...['agent.cordis.yml', 'agent.cordis.v2.yml'].map(name =>
            [path.join(packageDir, 'presets', 'maoying', name), removeObsoleteRow]),
        ...[path.join(home, 'cordis.patch.yml'), path.join(profileDir, 'cordis.patch.yml')]
            .map(file => [file, repairManagedBlocks]),
    ];
    // Validate all transformations before writing any file.
    const changes = candidates.filter(([file]) => fs.existsSync(file)).flatMap(([file, transform]) => {
        const old = fs.readFileSync(file, 'utf8');
        const text = transform(old);
        return text === old ? [] : [{ file, text }];
    });
    if (!changes.length) return [];
    const backup = path.join(home, 'backups', `maoying-compat-${randomUUID()}`);
    fs.mkdirSync(backup, { recursive: true, mode: 0o700 });
    changes.forEach(({ file, text }, index) => {
        fs.copyFileSync(file, path.join(backup, `${index}-${path.basename(file)}`));
        const temporary = `${file}.${randomUUID()}.tmp`;
        try {
            // Atomic replacement also detaches pnpm hardlinks instead of modifying its store.
            fs.writeFileSync(temporary, text, { flag: 'wx', mode: fs.statSync(file).mode });
            fs.renameSync(temporary, file);
        } finally {
            if (fs.existsSync(temporary)) fs.unlinkSync(temporary);
        }
    });
    console.log(`Maoying compatibility: repaired ${changes.length} files; backup: ${backup}`);
    return changes.map(({ file }) => file);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
    try {
        const [hostRoot, home, profile] = process.argv.slice(2);
        if (!hostRoot || !home || !profile) throw new Error('Usage: repair-dsh-maoying.mjs <host-root> <dsh-home> <profile>');
        repairMaoying({ hostRoot, home, profile });
    } catch (error) {
        console.error(`Maoying compatibility repair failed: ${error.message}`);
        process.exitCode = 1;
    }
}
