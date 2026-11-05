import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { repairMaoying } from '../repair-dsh-maoying.mjs';

const repo = fileURLToPath(new URL('../../..', import.meta.url));
const helper = fileURLToPath(new URL('../repair-dsh-maoying.mjs', import.meta.url));
const bash = process.platform === 'win32' ? 'C:/Program Files/Git/bin/bash.exe' : '/bin/bash';
const stale = '  - id: tool-subagent-list-agents\n    name: "@deepseek-ai/dsh-tool-subagent-control/list-agents"\n';
const source = 'plugins:\n  - id: tool-subagent-control\n    name: "@deepseek-ai/dsh-tool-subagent-control"\n'
    + stale + '  - id: delegation-outline\n    name: "@deepseek-ai/dsh-tool-subagent"\n';
const block = '# --- dsh-maoying preset managed (auto-generated; do not edit) ---\n'
    + source + '# --- end dsh-maoying preset managed ---\n';

function fixture(t, legacy = false) {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'maoying compatibility '));
    t.after(() => fs.rmSync(root, { recursive: true, force: true }));
    const home = path.join(root, 'custom dsh home');
    const hostRoot = path.join(root, 'global', '@deepseek-ai', 'dsh');
    const control = path.join(hostRoot, 'node_modules', '@deepseek-ai', 'dsh-tool-subagent-control');
    const pkg = path.join(home, 'profiles', 'web', 'node_modules', 'dsh-maoying');
    const write = (file, text) => {
        fs.mkdirSync(path.dirname(file), { recursive: true });
        fs.writeFileSync(file, text);
    };
    write(path.join(hostRoot, 'package.json'), '{}');
    write(path.join(control, 'package.json'), JSON.stringify({
        name: '@deepseek-ai/dsh-tool-subagent-control',
        exports: legacy ? { '.': './index.js', './list-agents': './list.js' } : { '.': './index.js' },
    }));
    write(path.join(control, 'index.js'), 'register({ name: "list_agents" });');
    write(path.join(control, 'list.js'), '// legacy tool');
    write(path.join(pkg, 'package.json'), '{}');
    const files = [
        ...['agent.cordis.yml', 'agent.cordis.v2.yml'].map(name => path.join(pkg, 'presets', 'maoying', name)),
        path.join(home, 'cordis.patch.yml'), path.join(home, 'profiles', 'web', 'cordis.patch.yml'),
    ];
    files.forEach((file, i) => write(file, i < 2 ? source : block));
    return { root, home, hostRoot, control, files, write, profile: 'web' };
}

test('modern host repairs sources and managed blocks, preserving user content and CRLF', t => {
    const f = fixture(t);
    const user = '# user-owned\n' + source;
    f.write(f.files[2], '\uFEFF' + (user + block + user).replaceAll('\n', '\r\n'));
    const before = f.files.map(file => fs.readFileSync(file, 'utf8'));
    assert.equal(repairMaoying(f).length, 4);
    assert.equal(fs.readFileSync(f.files[2], 'utf8'), '\uFEFF' + (user + block.replace(stale, '') + user).replaceAll('\n', '\r\n'));
    for (const file of f.files.slice(0, 2)) {
        assert.equal(fs.readFileSync(file, 'utf8'), source.replace(stale, ''));
    }
    const backup = path.join(f.home, 'backups', fs.readdirSync(path.join(f.home, 'backups'))[0]);
    before.forEach((text, index) => assert.equal(fs.readFileSync(path.join(backup, `${index}-${path.basename(f.files[index])}`), 'utf8'), text));
    const times = f.files.map(file => fs.statSync(file).mtimeMs);
    assert.deepEqual(repairMaoying(f), []);
    assert.deepEqual(f.files.map(file => fs.statSync(file).mtimeMs), times);
    assert.equal(fs.readdirSync(path.join(f.home, 'backups')).length, 1);
});

test('reinstalling the obsolete package is repaired again', t => {
    const f = fixture(t);
    repairMaoying(f);
    f.write(f.files[0], source);
    assert.deepEqual(repairMaoying(f), [f.files[0]]);
    assert.equal(fs.readFileSync(f.files[0], 'utf8'), source.replace(stale, ''));
});

test('legacy hosts keep their separate list_agents registration unchanged', t => {
    const f = fixture(t, true);
    assert.deepEqual(repairMaoying(f), []);
    assert.equal(fs.readFileSync(f.files[0], 'utf8'), source);
    assert.ok(!fs.existsSync(path.join(f.home, 'backups')));
});

test('missing package is a no-op; missing or unknown runtime fails without writes', t => {
    const f = fixture(t);
    assert.deepEqual(repairMaoying({ ...f, profile: 'absent' }), []);
    assert.throws(() => repairMaoying({ ...f, hostRoot: path.join(f.root, 'absent host') }), /Cannot find module/);
    f.write(path.join(f.control, 'index.js'), 'register({ name: "send_message" });');
    assert.throws(() => repairMaoying(f), /does not visibly provide/);
    assert.equal(fs.readFileSync(f.files[0], 'utf8'), source);
});

test('unexpected row fields or incomplete managed blocks abort before any writes', t => {
    const f = fixture(t);
    f.write(f.files[1], source.replace(stale, stale + '    config: { custom: true }\n'));
    assert.throws(() => repairMaoying(f), /unexpected fields/);
    assert.equal(fs.readFileSync(f.files[0], 'utf8'), source);
    f.write(f.files[1], source);
    f.write(f.files[3], block.replace('# --- end dsh-maoying preset managed ---', ''));
    assert.throws(() => repairMaoying(f), /Incomplete/);
    assert.equal(fs.readFileSync(f.files[0], 'utf8'), source);
});

test('misordered or nested markers leave every file unchanged', t => {
    const f = fixture(t);
    const begin = '# --- dsh-maoying preset managed (auto-generated; do not edit) ---\n';
    const end = '# --- end dsh-maoying preset managed ---\n';
    for (const malformed of [end + begin, begin + begin + end + end]) {
        f.write(f.files[3], malformed);
        assert.throws(() => repairMaoying(f), /managed block/);
        assert.equal(fs.readFileSync(f.files[0], 'utf8'), source);
    }
});

test('marker text inside example comments does not claim user-owned configuration', t => {
    const f = fixture(t);
    const user = '# example: # --- dsh-maoying preset managed (auto-generated; do not edit) ---\n'
        + source + '# example: # --- end dsh-maoying preset managed ---\n';
    f.write(f.files[2], user + block);
    repairMaoying(f);
    assert.equal(fs.readFileSync(f.files[2], 'utf8'), user + block.replace(stale, ''));
});

test('comment-only list_agents references do not enable repair', t => {
    const f = fixture(t);
    f.write(path.join(f.control, 'index.js'), '// name: "list_agents"\n/* name: "list_agents" */\nregister({name:"send_message"});');
    assert.throws(() => repairMaoying(f), /does not visibly provide/);
    assert.equal(fs.readFileSync(f.files[0], 'utf8'), source);
});

test('atomic replacement detaches hardlinks instead of corrupting a pnpm store', t => {
    const f = fixture(t);
    const store = path.join(f.root, 'pnpm-store-file');
    fs.linkSync(f.files[0], store);
    repairMaoying(f);
    assert.equal(fs.readFileSync(store, 'utf8'), source);
    assert.equal(fs.readFileSync(f.files[0], 'utf8'), source.replace(stale, ''));
});

test('CLI reports missing runtime with a nonzero exit', t => {
    const f = fixture(t);
    assert.throws(() => execFileSync(process.execPath, [helper, path.join(f.root, 'missing'), f.home, f.profile], { stdio: 'pipe' }),
        error => error.status === 1 && /repair failed/.test(error.stderr.toString()));
});

test('all installers invoke the same helper after Maoying plugin operations', () => {
    for (const name of ['install-linux.sh', 'install-mac.sh', 'install-windows.ps1']) {
        const text = fs.readFileSync(path.join(repo, name), 'utf8');
        const start = text.indexOf(name.endsWith('.ps1') ? 'function Install-OrUpdate-DshPlugin ' : 'dsh_plugin_install_or_update()');
        const fn = text.slice(start, text.indexOf('\n}\n', start) + 3);
        assert.match(fn, /repair-dsh-maoying\.mjs/);
        assert.ok(fn.indexOf('repair-dsh-maoying.mjs') > fn.indexOf('--latest'));
        if (name !== 'install-linux.sh') {
            assert.match(fn, /ELECTRON_RUN_AS_NODE/);
            assert.match(fn, /app\.asar\/dsh/);
        }
    }
});

function installerFunction(name, marker) {
    const text = fs.readFileSync(path.join(repo, name), 'utf8').replaceAll('\r\n', '\n');
    const start = text.indexOf(marker);
    return text.slice(start, text.indexOf('\n}\n', start) + 3);
}

for (const installer of ['install-linux.sh', 'install-mac.sh']) {
    for (const operation of ['add', 'update']) {
        test(`${installer}: ${operation} and repeated reinstall execute the real compatibility helper`, {
            skip: !fs.existsSync(bash),
        }, t => {
            const f = fixture(t);
            const original = path.join(f.root, 'original.yml');
            f.write(original, source);
            const quote = value => `'${value.replaceAll("'", "'\\''")}'`;
            const script = `set -euo pipefail
DOTFILES_DIR=${quote(repo.replaceAll('\\', '/'))}
DSH_HOME=${quote(f.home.replaceAll('\\', '/'))}
npm() { printf '%s\\n' ${quote(path.join(f.root, 'global').replaceAll('\\', '/'))}; }
log() { :; }
warn() { printf '%s\\n' "$*" >&2; }
dsh_plugin_failure_reason() { warn "$*"; }
dsh_plugin_name() { printf '%s\\n' "$1"; }
dsh() {
  case "$*" in
    *' list') ${operation === 'update' ? "printf 'dsh-maoying@0.1.38\\n'" : ':'} ;;
    *) cp ${quote(original.replaceAll('\\', '/'))} ${quote(f.files[0].replaceAll('\\', '/'))} ;;
  esac
}
${installerFunction(installer, 'dsh_plugin_install_or_update()')}
dsh_plugin_install_or_update web dsh-maoying
dsh_plugin_install_or_update web dsh-maoying
`;
            execFileSync(bash, ['--noprofile', '--norc', '-s'], { input: script, encoding: 'utf8' });
            assert.equal(fs.readFileSync(f.files[0], 'utf8'), source.replace(stale, ''));
            assert.equal(fs.readdirSync(path.join(f.home, 'backups')).length, 2);
        });
    }
}

for (const operation of ['add', 'update']) {
    test(`Windows PowerShell: ${operation} and reinstall execute the real compatibility helper`, {
        skip: process.platform !== 'win32',
    }, t => {
        const f = fixture(t);
        const quote = value => `'${value.replaceAll("'", "''")}'`;
        const script = `$ErrorActionPreference='Stop'
$DotfilesDir=${quote(repo)}
$DshHome=${quote(f.home)}
function Get-DshPluginName($Spec) { $Spec }
function Write-Step($Message) { }
function Write-Warn2($Message) { throw $Message }
function Show-DshPluginFailure($Output) { throw ($Output | Out-String) }
function npm { ${quote(path.join(f.root, 'global'))} }
function dsh {
    $global:LASTEXITCODE=0
    if ($args[-1] -eq 'list') { ${operation === 'update' ? "'dsh-maoying@0.1.38'" : ''} }
    else { [IO.File]::WriteAllText(${quote(f.files[0])}, ${quote(source)}) }
}
${installerFunction('install-windows.ps1', 'function Install-OrUpdate-DshPlugin ')}
Install-OrUpdate-DshPlugin web dsh-maoying
Install-OrUpdate-DshPlugin web dsh-maoying
`;
        const file = path.join(f.root, 'installer-test.ps1');
        f.write(file, script);
        execFileSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', file], { encoding: 'utf8' });
        assert.equal(fs.readFileSync(f.files[0], 'utf8'), source.replace(stale, ''));
        assert.equal(fs.readdirSync(path.join(f.home, 'backups')).length, 2);
    });
}

test('macOS Desktop uses its bundled runtime and restores the parent environment', {
    skip: !fs.existsSync(bash),
}, t => {
    const f = fixture(t);
    const app = path.join(f.root, 'DeepSeek Harness.app');
    const host = path.join(app, 'Contents', 'Resources', 'app.asar', 'dsh');
    fs.cpSync(f.hostRoot, host, { recursive: true });
    const desktop = path.join(f.home, 'profiles', 'desktop');
    fs.renameSync(path.join(f.home, 'profiles', 'web'), desktop);
    const quote = value => `'${value.replaceAll('\\', '/').replaceAll("'", "'\\''")}'`;
    const runtime = path.join(app, 'Contents', 'MacOS', 'DeepSeek Harness');
    f.write(runtime, '#!/bin/bash\n[ "$ELECTRON_RUN_AS_NODE" = 1 ] || exit 42\nexec node "$@"\n');
    fs.chmodSync(runtime, 0o755);
    const command = path.join(app, 'Contents', 'Resources', 'runtime', 'cli', 'bin', 'dsh');
    f.write(command, '#!/bin/bash\ncase "$*" in *" list") echo dsh-maoying@0.1.38;; esac\n');
    fs.chmodSync(command, 0o755);
    execFileSync(bash, ['--noprofile', '--norc', '-s'], {
        input: `set -euo pipefail
DOTFILES_DIR=${quote(repo)}
DSH_HOME=${quote(f.home)}
export ELECTRON_RUN_AS_NODE=keep
log() { :; }
warn() { echo "$*" >&2; exit 1; }
dsh_plugin_failure_reason() { warn "$*"; }
dsh_plugin_name() { echo "$1"; }
${installerFunction('install-mac.sh', 'dsh_plugin_install_or_update()')}
dsh_plugin_install_or_update desktop dsh-maoying ${quote(command)}
[ "$ELECTRON_RUN_AS_NODE" = keep ]
`, encoding: 'utf8',
    });
    assert.equal(fs.readFileSync(path.join(desktop, 'node_modules/dsh-maoying/presets/maoying/agent.cordis.yml'), 'utf8'), source.replace(stale, ''));
});

// Opt in with a known modern Desktop build; legacy installations correctly need no repair.
const desktopExe = process.env.DSH_DESKTOP_TEST_EXE;
test('installed Windows Electron runtime resolves its real asar host and repairs a sandbox profile', {
    skip: process.platform !== 'win32' || !desktopExe || !fs.existsSync(desktopExe),
}, t => {
    const f = fixture(t);
    execFileSync(desktopExe, [helper, path.join(path.dirname(desktopExe), 'resources/app.asar/dsh'), f.home, f.profile], {
        env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' }, encoding: 'utf8',
    });
    assert.equal(fs.readFileSync(f.files[0], 'utf8'), source.replace(stale, ''));
});
