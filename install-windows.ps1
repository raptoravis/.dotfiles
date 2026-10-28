# install-windows.ps1 — Windows host dotfiles & dev environment bootstrap
#
# Usage (run from a regular PowerShell prompt — admin not required for Scoop):
#   powershell -ExecutionPolicy Bypass -File .\install-windows.ps1
#   .\install-windows.ps1 -DotfilesDir "$env:USERPROFILE\.dotfiles"
#
# Idempotent: safe to re-run. Mirrors `cargo make init` for Windows host.
# This script targets the Windows host (Scoop, native GUI apps). For the
# WSL / unix backend layer, run install-linux.sh inside WSL.

[CmdletBinding()]
param(
    [string]$DotfilesDir = $PSScriptRoot,
    # HTTP proxy applied as user-level HTTPS_PROXY/HTTP_PROXY/ALL_PROXY and to
    # `git config --global`. Mirrors $env:PROXY_URL in the pwsh profile so
    # tools launched outside pwsh (vscode, etc.) reach
    # the network through the same proxy. Pass '' to skip.
    [string]$ProxyUrl = 'http://127.0.0.1:7890',
    # Uninstall all AI agent CLIs and the agent tooling this script installs
    # (Claude Code, Codex, OpenCode, Grok, DeepSeek Harness CLI/TUI/Desktop,
    # omp, oh-my-codex, herdr, bmad-loop, zg, hostc, claude-mem,
    # agent-browser): stop their
    # processes/services, run the Desktop uninstaller, remove npm packages,
    # config/data/cache dirs, skills checkouts, Cursor skill links and PATH
    # entries. Shared runtimes (bun, Node, npm/pnpm caches) are kept.
    [switch]$UninstallAgents
)

if (-not $DotfilesDir) {
    $DotfilesDir = Join-Path $env:USERPROFILE '.dotfiles'
}

$ErrorActionPreference = 'Continue'   # keep going on per-package errors
Set-StrictMode -Version Latest
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Step  ($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Warn2 ($msg) { Write-Host "[warn] $msg" -ForegroundColor Yellow }
function Write-Err2  ($msg) { Write-Host "[err]  $msg" -ForegroundColor Red }
function Test-Cmd ($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }
# 安装/升级一个 npm 全局 CLI。`npm install -g` 不看已装版本、每次都拉 latest 重装，
# 已是最新也白跑。这里先比 installed vs latest：未安装或远端有新版才真正 install。
function Test-SemverLt($a, $b) {
    # A < B (npm semver) 判断。用 node 比较（npm 依赖 node），预发布标签也能正确排序，
    # 避免把「本地比 latest 新」误判成可升级。
    $js = 'const n = (v) => {
      const m = String(v).replace(/^v/, "").split("-");
      return { core: m[0].split(".").map((x) => +x || 0), pre: m[1] ? m[1].split(".") : [] };
    };
    const a = n(process.argv[1]), b = n(process.argv[2]);
    for (let i = 0; i < 3; i++) { const d = a.core[i] - b.core[i]; if (d) process.exit(d < 0 ? 0 : 1); }
    const cmp = (x, y) => {
      for (let i = 0; i < Math.max(x.length, y.length); i++) {
        if (x[i] === undefined) return -1;
        if (y[i] === undefined) return 1;
        if (x[i] === y[i]) continue;
        const xn = /^\d+$/.test(x[i]), yn = /^\d+$/.test(y[i]);
        if (xn && yn) return (+x[i]) - (+y[i]);
        if (xn) return -1;
        if (yn) return 1;
        return x[i] < y[i] ? -1 : 1;
      }
      return 0;
    };
    if (a.pre.length === 0 && b.pre.length === 0) process.exit(1);
    if (a.pre.length === 0) process.exit(1);
    if (b.pre.length === 0) process.exit(0);
    process.exit(cmp(a.pre, b.pre) < 0 ? 0 : 1);'
    node -e $js $a $b 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}
function Test-SemverSafeUpgrade($a, $b) {
    # A→B 是否安全自动升级：B 非预发布，且仅同 minor 的 patch 级（0.x 的 minor 视为破坏性）。
    # 预发布 latest 与跨 minor/major 的跳跃对其他 CLI 判为不安全。
    $js = 'const n = (v) => {
      const m = String(v).replace(/^v/, "").split("-");
      return { core: m[0].split(".").map((x) => +x || 0), pre: m[1] };
    };
    const a = n(process.argv[1]), b = n(process.argv[2]);
    if (b.pre) process.exit(1);
    if (a.core[0] !== b.core[0]) process.exit(1);
    if (a.core[0] === 0 && a.core[1] !== b.core[1]) process.exit(1);
    process.exit(0);'
    node -e $js $a $b 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}
function Install-NpmCliIfStale ($pkg, $label) {
    $inst = npm list -g --depth=0 $pkg 2>$null | ForEach-Object { if ($_ -match '@([^@]+)$') { $matches[1] } } | Select-Object -First 1
    if (-not $inst) {
        Write-Step "Installing $label ($pkg)"
        npm install -g $pkg
        if ($LASTEXITCODE -ne 0) { Write-Warn2 "  $label install failed" }
        return
    }
    $latest = ((npm view $pkg version 2>$null) | Select-Object -Last 1)
    if ($latest) { $latest = $latest.Trim() }
    if ($latest -and (Test-SemverLt $inst $latest)) {
        if ($pkg -in @('@deepseek-ai/dsh', '@deepseek-harness-tui/dsh-tui') -or (Test-SemverSafeUpgrade $inst $latest)) {
            Write-Step "Upgrading $label ($pkg): $inst -> $latest"
            npm install -g $pkg
            if ($LASTEXITCODE -ne 0) { Write-Warn2 "  $label upgrade failed" }
        } else {
            Write-Host "  $label ($pkg) @ $inst → $latest 跨 minor/major 或为预发布，跳过自动升级"
        }
    } elseif ($latest -and (Test-SemverLt $latest $inst)) {
        Write-Host "  $label ($pkg) @ $inst 比 latest ($latest) 新，跳过"
    } else {
        Write-Host "  $label ($pkg) @ $inst 已是最新，跳过"
    }
}
function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }

if ($UninstallAgents) {
    Write-Step 'Uninstalling AI agent CLIs and cleaning config directories'

    # Remove only agent-owned paths. Shared runtimes (bun, Node, npm/pnpm caches)
    # and unrelated agent/IDE installs are intentionally kept.

    # 1) Stop running agents and agent-owned services first: deleting files under
    # a live process leaves locked files behind, and the Codex sandbox helper
    # service would otherwise outlive its CLI.
    Write-Step '  stopping running agent processes'
    foreach ($procName in @('herdr', 'zg', 'zvec-grep', 'opencode', 'dsh', 'dsh-tui', 'DeepSeek Harness')) {
        $procs = @(Get-Process -Name $procName -ErrorAction SilentlyContinue)
        foreach ($proc in $procs) {
            Write-Step "  stop $($proc.ProcessName) ($($proc.Id))"
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
    }
    $CodexSandboxService = 'CodexSandboxService.OpenAI.Codex'
    if (Get-Service -Name $CodexSandboxService -ErrorAction SilentlyContinue) {
        Write-Step "  stop/remove service $CodexSandboxService"
        Stop-Service -Name $CodexSandboxService -Force -ErrorAction SilentlyContinue
        # Deleting a service needs an elevated shell; warn instead of failing the run.
        $null = sc.exe delete $CodexSandboxService 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Warn2 '  could not delete the Codex sandbox service (re-run from an elevated shell to remove it)' }
    }

    # 2) DeepSeek Harness Desktop: run its registered uninstaller so the app, its
    # registry entry and shortcuts are removed, then drop any leftover app data.
    $DesktopRecord = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'DeepSeek Harness *' -and $_.UninstallString } | Select-Object -First 1
    if ($DesktopRecord) {
        $UninstallExe = $null
        if ($DesktopRecord.UninstallString -match '^\s*"([^"]+)"') { $UninstallExe = $Matches[1] }
        elseif ($DesktopRecord.UninstallString -match '^\s*(\S+)') { $UninstallExe = $Matches[1] }
        if ($UninstallExe -and (Test-Path -LiteralPath $UninstallExe)) {
            Write-Step "  uninstalling DeepSeek Harness Desktop ($($DesktopRecord.DisplayVersion))"
            Start-Process -FilePath $UninstallExe -ArgumentList '/S', '/currentuser' -Wait -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        } else {
            Write-Warn2 '  DeepSeek Harness Desktop uninstaller not found; removing its files instead'
        }
    }
    foreach ($desktopDir in @(
        (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness'),
        (Join-Path $env:APPDATA 'DeepSeek Harness'),
        (Join-Path $env:LOCALAPPDATA 'DeepSeek Harness')
    )) {
        if (Test-Path -LiteralPath $desktopDir) {
            Write-Step "  rm -r -fo $desktopDir"
            Remove-Item -Recurse -Force -LiteralPath $desktopDir -ErrorAction SilentlyContinue
        }
    }

    # 3) npm global uninstall — every agent/agent-tooling CLI the install above adds.
    # pnpm, playwright and other shared dev tools are kept.
    if (Test-Cmd npm) {
        $AgentPackages = @(
            '@anthropic-ai/claude-code',
            '@openai/codex',
            'oh-my-codex',
            '@opencode/cli',
            '@xai-official/grok',
            '@deepseek-ai/dsh',
            '@deepseek-harness-tui/dsh-tui',
            '@zvec/zvec-grep',
            'hostc',
            'claude-mem',
            'agent-browser',
            'puppeteer'
        )
        foreach ($pkg in $AgentPackages) {
            Write-Step "  npm uninstall -g $pkg"
            npm uninstall -g $pkg 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Warn2 "  $pkg was not installed globally (or uninstall failed)"
            }
        }
    } else {
        Write-Warn2 'npm not on PATH -- skipping npm uninstall step'
    }

    # 3b) uv-tool CLIs — bmad-loop installs as a `uv tool` (see 7e5 below), so it
    #     has no npm package to uninstall.
    if (Test-Cmd uv) {
        Write-Step '  uv tool uninstall bmad-loop'
        uv tool uninstall bmad-loop 2>$null | Out-Null
    } else {
        Write-Warn2 'uv not on PATH -- skipping uv tool uninstall step'
    }

    # 4) Agent config, data, cache and skills-checkout paths. Files (.claude.json)
    # are handled by the same helper as directories.
    $AgentPaths = @(
        (Join-Path $env:USERPROFILE '.claude'),
        (Join-Path $env:USERPROFILE '.claude.json'),
        (Join-Path $env:USERPROFILE '.claude.json.backup'),
        $CodexHome,
        (Join-Path $env:USERPROFILE '.config\opencode'),
        (Join-Path $env:USERPROFILE '.local\share\opencode'),
        (Join-Path $env:USERPROFILE '.local\state\opencode'),
        (Join-Path $env:USERPROFILE '.grok'),
        $DshHome,
        (Join-Path $env:USERPROFILE '.omp'),
        (Join-Path $env:LOCALAPPDATA 'omp'),
        (Join-Path $env:USERPROFILE '.agents'),
        (Join-Path $env:USERPROFILE '.herdr'),
        (Join-Path $env:USERPROFILE '.config\herdr'),
        (Join-Path $env:LOCALAPPDATA 'herdr'),
        # bmad-loop's native-Windows state root (run state itself is per project).
        (Join-Path $env:LOCALAPPDATA 'bmad-loop'),
        (Join-Path $env:USERPROFILE '.zvec-grep'),
        (Join-Path $env:USERPROFILE '.agent-browser'),
        (Join-Path $env:USERPROFILE '.local\share\yunxing'),
        (Join-Path $env:USERPROFILE '.local\share\bmad-method'),
        (Join-Path $env:USERPROFILE '.local\share\taste-skill'),
        (Join-Path $env:USERPROFILE '.cache\dotfiles\agent-plugins'),
        (Join-Path $env:USERPROFILE '.cache\opencode'),
        (Join-Path $env:USERPROFILE '.cache\claude'),
        (Join-Path $env:USERPROFILE '.cache\codex'),
        (Join-Path $env:USERPROFILE '.cache\codex-runtimes'),
        (Join-Path $env:USERPROFILE '.cache\dsh'),
        (Join-Path $env:USERPROFILE '.cache\puppeteer'),
        (Join-Path $env:USERPROFILE '.cache\chrome-devtools-mcp')
    )
    foreach ($p in $AgentPaths) {
        if (-not (Test-Path -LiteralPath $p)) {
            Write-Step "  skip (not found): $p"
            continue
        }
        $item = Get-Item -LiteralPath $p -Force
        if ($item.PSIsContainer) {
            Write-Step "  rm -r -fo $p"
            Remove-Item -Recurse -Force -LiteralPath $p -ErrorAction SilentlyContinue
        } else {
            Write-Step "  rm -fo $p"
            Remove-Item -Force -LiteralPath $p -ErrorAction SilentlyContinue
        }
    }

    # 5) omp installs into the shared bun dir; remove only its shims, not bun itself.
    foreach ($ompShim in @(
        (Join-Path $env:USERPROFILE '.bun\bin\omp.exe'),
        (Join-Path $env:USERPROFILE '.bun\bin\omp.bunx'),
        (Join-Path $env:USERPROFILE '.bun\bin\omp.cmd'),
        (Join-Path $env:USERPROFILE '.bun\bin\omp.ps1')
    )) {
        if (Test-Path -LiteralPath $ompShim) {
            Write-Step "  rm -fo $ompShim"
            Remove-Item -Force -LiteralPath $ompShim -ErrorAction SilentlyContinue
        }
    }

    # 6) Cursor keeps the user's IDE settings, so only drop the skill links this
    # repo created (they point into the removed ~/.local/share checkouts).
    $CursorSkills = Join-Path $env:USERPROFILE '.cursor\skills'
    if (Test-Path -LiteralPath $CursorSkills) {
        $cursorLinks = @(Get-ChildItem -LiteralPath $CursorSkills -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.LinkType -and ((@($_.Target) -join ';') -like '*\.local\share\*') })
        foreach ($link in $cursorLinks) {
            Write-Step "  rm skill link $($link.Name)"
            cmd /c rmdir "$($link.FullName)" 2>$null | Out-Null
        }
    }

    # 7) Remove the PATH entries the agent installers appended; ~/.bun\bin stays
    # because bun is a shared runtime. Empty segments are dropped too.
    $UserPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    if ($UserPath) {
        $KeptPath = @(($UserPath -split ';') | Where-Object { $_ -and ($_ -notmatch '\\\.herdr\\|\\\.grok\\bin') })
        $NewPath = $KeptPath -join ';'
        if ($NewPath -ne $UserPath) {
            Write-Step '  removing agent PATH entries from the user environment'
            [Environment]::SetEnvironmentVariable('PATH', $NewPath, 'User')
        }
    }

    Write-Step 'Agent uninstall complete.'
    return
}

function Install-Scoop {
    # Scoop's installer blocks running as admin by default.
    # Detect elevation and pass -RunAsAdmin if needed.
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
    if (Test-Admin) {
        $installer = Join-Path $env:TEMP 'scoop-install.ps1'
        Invoke-RestMethod -Uri 'https://get.scoop.sh' -OutFile $installer
        try       { & $installer -RunAsAdmin }
        finally   { Remove-Item $installer -ErrorAction SilentlyContinue }
    } else {
        Invoke-RestMethod -Uri 'https://get.scoop.sh' | Invoke-Expression
    }
}

# ---------------------------------------------------------------------------
# 1) Scoop (user-scope package manager — no admin required)
# ---------------------------------------------------------------------------
if (-not (Test-Cmd scoop)) {
    Write-Step 'Installing Scoop'
    Install-Scoop
} else {
    # Scoop shim found on PATH — verify the actual app is functional.
    # Common failure mode: the shim exists but the scoop app was accidentally
    # deleted / corrupted, so `scoop ...` calls fail with "not recognized".
    $scoopApp = Join-Path $env:USERPROFILE 'scoop\apps\scoop\current\bin\scoop.ps1'
    if (-not (Test-Path $scoopApp)) {
        Write-Warn2 'Scoop shim found but scoop app is missing — reinstalling'
        # Remove broken shims + the scoop app dir so the installer starts clean.
        Remove-Item "$env:USERPROFILE\scoop\shims" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:USERPROFILE\scoop\apps\scoop" -Recurse -Force -ErrorAction SilentlyContinue
        Install-Scoop
    } else {
        Write-Step "Scoop already installed: $(scoop --version | Select-Object -First 1)"
    }
}

# git is needed for buckets and many manifests; install up-front and silently.
if (-not (Test-Cmd git)) {
    Write-Step 'Installing git via Scoop'
    scoop install git | Out-Null
}

# ---------------------------------------------------------------------------
# 2) Scoop buckets
# ---------------------------------------------------------------------------
Write-Step 'Adding Scoop buckets (extras, nerd-fonts, versions)'
scoop bucket add extras     *>$null
scoop bucket add nerd-fonts *>$null
scoop bucket add versions   *>$null

# ---------------------------------------------------------------------------
# 3) Core tools, languages, dependencies (matches Makefile.toml `windows-tools`)
# ---------------------------------------------------------------------------
$Tools = @(
    'lazygit', 'gh', 'neovim', 'yazi', 'windows-terminal',
    'fzf', 'ripgrep', 'bat',
    'starship', 'fd',
    'cloudflared',
    'witr',
    'cyberduck',
    'sniffnet',
    'FiraCode-NF',
    'jq', 'vhs', 'silicon', 'ffmpeg', 'ast-grep',
    'dotter'
)
$Languages = @('python', 'go', 'lua', 'lua51', 'luarocks', 'stylua')
# tree-sitter CLI is required by nvim-treesitter (main) to compile parsers.
$Deps      = @('autohotkey', 'cmake', 'fastfetch', 'firacode', 'tree-sitter')

# Snapshot installed scoop apps once. `scoop export` emits JSON (apps[].Name);
# fall back to parsing `scoop list` on older scoop versions.
$InstalledScoop = @()
try {
    $exported = (scoop export 2>$null) | ConvertFrom-Json
    if ($exported -and $exported.apps) {
        $InstalledScoop = @($exported.apps | ForEach-Object { $_.Name })
    }
} catch {
    $InstalledScoop = @(scoop list 2>$null | ForEach-Object { $_.Name } | Where-Object { $_ })
}

# Packages that run as a Windows service (cloudflared). The running service holds
# the scoop shim open, so `scoop update` fails to replace it (Access denied / in
# use). A LocalSystem service can't be killed with `Stop-Process` from a standard
# user -- it must be stopped via `sc.exe stop`, which needs an admin token.
# Admin runs stop/update/start directly; non-admin runs elevate via UAC and fall
# back to a skip + pointer if the user declines the prompt.
$ScoopServices = @('cloudflared')

function Test-ScoopServiceRunning($pkg) {
    $svc = Get-Service -Name $pkg -ErrorAction SilentlyContinue
    return ($null -ne $svc -and $svc.Status -eq 'Running')
}

# Detect whether scoop has a newer version of $pkg than what's installed.
# `scoop status` refreshes the buckets (network) then emits one object per
# outdated app (with a Name property), so $pkg appearing there means an update
# is available. We check this instead of trying `scoop update` first: a
# non-elevated update against a running service still tears down the shim
# (access-denied spam) and returns exit 0, so its exit code can't be trusted
# to mean "no update".
function Test-ScoopAppOutdated($pkg) {
    $status = scoop status 2>$null
    return ($null -ne ($status | Where-Object { $_.Name -eq $pkg }))
}

# Stop the scoop-managed service for $pkg so its shim can be replaced. Returns
# $true when it's safe to update (stopped, already stopped, or not registered);
# $false when the stop failed (e.g. no admin token) and the update must be skipped.
function Stop-ScoopService($pkg) {
    $svc = Get-Service -Name $pkg -ErrorAction SilentlyContinue
    if ($null -eq $svc -or $svc.Status -eq 'Stopped') { return $true }

    try {
        if ($svc.Status -ne 'StopPending') {
            Stop-Service -InputObject $svc -ErrorAction Stop
        }
        $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
        return $true
    } catch {
        Write-Warn2 "  could not stop $pkg service: $($_.Exception.Message)"
        return $false
    }
}

# Restart the service we stopped and wait until SCM reports it running. Returns
# $false if startup fails so callers cannot silently leave the service down.
function Start-ScoopService($pkg) {
    $svc = Get-Service -Name $pkg -ErrorAction SilentlyContinue
    if ($null -eq $svc -or $svc.StartType -eq 'Disabled') { return $true }

    try {
        if ($svc.Status -eq 'StopPending') {
            $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
        }
        if ($svc.Status -ne 'Running') {
            Start-Service -InputObject $svc -ErrorAction Stop
            $svc.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
        }
        return $true
    } catch {
        Write-Warn2 "  could not start $pkg service: $($_.Exception.Message)"
        return $false
    }
}

# Non-admin path: elevate via UAC to run `stop -> update -> start` for a service
# package. Output is captured to a temp log and replayed. If the user declines
# UAC, fall back to a skip + pointer.
function Invoke-ScoopServiceUpdateElevated($pkg) {
    $log = Join-Path $env:TEMP "$pkg-scoop-update.log"
    Remove-Item $log -ErrorAction SilentlyContinue
    # Stop-Service/Start-Service return before every transition is necessarily
    # complete. Explicit waits prevent start racing a still-STOP_PENDING service.
    # The finally block restores the service even when the package update fails.
    $inner = @'
& {
    $ErrorActionPreference = 'Stop'
    $pkg = '__PKG__'
    $svc = Get-Service -Name $pkg -ErrorAction Stop
    $updateExit = 0

    try {
        if ($svc.Status -ne 'Stopped') {
            Stop-Service -InputObject $svc -ErrorAction Stop
            $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
        }

        scoop update $pkg
        $updateExit = $LASTEXITCODE
    } finally {
        $svc = Get-Service -Name $pkg -ErrorAction Stop
        if ($svc.Status -eq 'StopPending') {
            $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
        }
        if ($svc.Status -ne 'Running') {
            Start-Service -InputObject $svc -ErrorAction Stop
            $svc.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
        }
    }

    sc.exe query $pkg
    if ($updateExit -ne 0) { exit $updateExit }
}
'@.Replace('__PKG__', $pkg)
    $inner = "$inner *>> '$log'"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
    try {
        $proc = Start-Process -Verb RunAs -Wait -PassThru powershell -ArgumentList '-NoProfile','-EncodedCommand',$enc
        if (Test-Path $log) { Get-Content $log | ForEach-Object { Write-Host "    $_" } }
        if ($proc.ExitCode -ne 0) { Write-Warn2 "  $pkg elevated update failed (exit $($proc.ExitCode))" }
    } catch {
        Write-Warn2 "  $pkg update skipped -- elevation declined. Run in an admin shell: sc.exe stop $pkg; scoop update $pkg; sc.exe start $pkg"
    }
}

# Stop only the scoop-managed instance of $pkg, so unrelated same-named programs
# on the system are untouched. Matches both the app dir (process started from the
# versioned exe) AND the shim exe (process started via `scoop\shims\<pkg>.exe`,
# e.g. a cloudflared tunnel) -- the shim holder is what locks the file scoop must
# replace during `scoop update`.
function Stop-ScoopAppProcesses($pkg) {
    $appDir  = Join-Path $env:USERPROFILE "scoop\apps\$pkg"
    $shimExe = Join-Path $env:USERPROFILE "scoop\shims\$pkg.exe"
    Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and (
            $_.Path.StartsWith($appDir, [System.StringComparison]::OrdinalIgnoreCase) -or
            $_.Path.Equals($shimExe, [System.StringComparison]::OrdinalIgnoreCase)
        )
    } | ForEach-Object {
        Write-Host "    stopping $($_.ProcessName) (pid $($_.Id)) before update"
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }
}

# Package name -> process name, where they differ (default: same as package).
# Used to detect a running app and skip its update instead of letting scoop
# print a wall of "instances still running" errors.
$ScoopProcName = @{
    'nodejs-lts' = 'node'
    'neovim'     = 'nvim'
}
function Test-ScoopAppRunning($pkg) {
    $proc = if ($script:ScoopProcName.ContainsKey($pkg)) { $script:ScoopProcName[$pkg] } else { $pkg }
    [bool](Get-Process -Name $proc -ErrorAction SilentlyContinue)
}

function Install-ScoopPackages($label, $pkgs) {
    Write-Step "Installing $label"
    foreach ($p in $pkgs) {
        if ($script:InstalledScoop -contains $p) {
            if ($script:ScoopServices -contains $p) {
                # Windows-service package: stop the service, update, restart it.
                Write-Host "  $p already installed -- updating (service)"
                if (Test-Admin) {
                    if (Stop-ScoopService $p) {
                        Stop-ScoopAppProcesses $p   # clear any stray non-service process
                        try {
                            scoop update $p
                            if ($LASTEXITCODE -ne 0) { Write-Warn2 "  update failed: $p" }
                        } finally {
                            if (-not (Start-ScoopService $p)) {
                                Write-Warn2 "  $p service remains stopped; start it manually after fixing the error"
                            }
                        }
                    } else {
                        Write-Warn2 "  $p update skipped -- could not stop service"
                    }
                } else {
                    if (Test-ScoopServiceRunning $p) {
                        # Service is running. Elevate (UAC) only when a newer
                        # version is actually available — otherwise leave it alone.
                        if (Test-ScoopAppOutdated $p) {
                            Invoke-ScoopServiceUpdateElevated $p
                        } else {
                            Write-Host "  $p already up to date -- skip (no elevation)"
                        }
                    } else {
                        # Service not running — a plain user-scope update suffices,
                        # no elevation needed.
                        Stop-ScoopAppProcesses $p   # clear any stray non-service process
                        scoop update $p
                        if ($LASTEXITCODE -ne 0) { Write-Warn2 "  update failed: $p" }
                    }
                }
            } elseif (Test-ScoopAppRunning $p) {
                # Interactive/long-running app (nvim, node...): don't kill it,
                # don't let scoop spam errors -- just skip this update.
                Write-Host "  $p already installed -- running, skip update"
            } else {
                Write-Host "  $p already installed -- updating"
                scoop update $p
                if ($LASTEXITCODE -ne 0) { Write-Warn2 "  update failed: $p" }
            }
        } else {
            scoop install $p
            if ($LASTEXITCODE -ne 0) { Write-Warn2 "  failed: $p" }
        }
    }
}

Install-ScoopPackages 'core tools'   $Tools
Install-ScoopPackages 'languages'    $Languages
Install-ScoopPackages 'dependencies' $Deps

# Ensure scoop shims are on PATH for the current session so freshly-installed
# packages (node, npm, corepack, cargo, etc.) are immediately available
# without requiring a new terminal.
$ScoopShims = Join-Path $env:USERPROFILE 'scoop\shims'
if ($ScoopShims -notin ($env:Path -split ';')) {
    $env:Path = "$ScoopShims;$env:Path"
}

# VS Code — primary editor; available from extras bucket.
if (-not (Test-Cmd code)) {
    Write-Step 'Installing VS Code via Scoop'
    scoop install vscode
    if ($LASTEXITCODE -ne 0) { Write-Warn2 '  failed: vscode' }
} else {
    Write-Host '  VS Code already installed'
}

# Telescope FZF Native (Neovim) and `cc`/`link` crate builds need a C compiler
# and linker. VS Build Tools (step 4d) provides cl.exe + link.exe. Resolve the
# MSVC toolchain directory via vswhere and add it to the session PATH so Rust /
# Neovim / Python native extensions use the VS linker instead of MinGW GCC.
$VsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$MsvcDir = ''
if (Test-Path $VsWhere) {
    $vsPath = & $VsWhere -latest -products '*' -requires 'Microsoft.VisualStudio.Workload.VCTools' -property installationPath 2>$null
    if ($vsPath) {
        $msvcRoot = Join-Path $vsPath 'VC\Tools\MSVC'
        $latestMs = Get-ChildItem $msvcRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
        if ($latestMs) { $MsvcDir = Join-Path $latestMs.FullName 'bin\Hostx64\x64' }
    }
}
if ($MsvcDir -and (Test-Path (Join-Path $MsvcDir 'cl.exe'))) {
    $env:Path = "$MsvcDir;$env:Path"
    Write-Step "VS toolchain: cl.exe + link.exe found at $MsvcDir"
    Write-Host '  New terminals should run vcvarsall.bat or use "Developer Command Prompt for VS 2022"'
} else {
    # Fallback: install MinGW gcc via scoop so Telescope FZF / cc crate still work
    Write-Step 'Installing gcc (MinGW) via Scoop — VS Build Tools not detected'
    scoop install gcc 2>$null | Out-Null
    $gccScoop = Join-Path $env:USERPROFILE 'scoop\apps\gcc\current\bin\gcc.exe'
    if (Test-Path $gccScoop) {
        scoop shim add gcc $gccScoop 2>$null | Out-Null
        Write-Host '  gcc shim added for Neovim Telescope FZF Native (fallback)'
    }
}

# ---------------------------------------------------------------------------
# 3b) Node.js — Chocolatey (system-wide PATH) with Scoop fallback
# ---------------------------------------------------------------------------
if (-not (Test-Cmd node)) {
    if (Test-Admin) {
        # Install Chocolatey if not present
        if (-not (Test-Cmd choco)) {
            Write-Step 'Installing Chocolatey'
            try {
                irm 'https://community.chocolatey.org/install.ps1' | iex
            } catch {
                Write-Warn2 "  Chocolatey install failed: $_"
            }
        }
        if (Test-Cmd choco) {
            Write-Step 'Installing Node.js via Chocolatey'
            choco install nodejs --version='24.18.0' -y --no-progress --no-color 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                # Refresh PATH so node/npm are available in this session
                $chocoBin = Join-Path $env:ProgramData 'chocolatey\bin'
                if ($chocoBin -notin ($env:Path -split ';')) {
                    $env:Path = "$chocoBin;$env:Path"
                }
                $refreshEnv = Join-Path $env:ProgramData 'chocolatey\bin\refreshenv.cmd'
                if (Test-Path $refreshEnv) { cmd /c $refreshEnv 2>$null }
            } else {
                Write-Warn2 '  Chocolatey nodejs install failed — falling back to Scoop'
            }
        } else {
            Write-Warn2 '  Chocolatey not available — falling back to Scoop for Node.js'
        }
    } else {
        Write-Warn2 '  Not running as admin — falling back to Scoop for Node.js'
    }
    # Fallback: install via Scoop if Chocolatey didn't succeed
    if (-not (Test-Cmd node)) {
        Write-Step 'Installing Node.js via Scoop (fallback)'
        scoop install nodejs-lts
    }
} else {
    Write-Step "Node.js already installed: $(node -v)"
}
# Ensure npm is on PATH for the npm-tools section below
if (-not (Test-Cmd npm)) {
    $ScoopShims = Join-Path $env:USERPROFILE 'scoop\shims'
    if ($ScoopShims -notin ($env:Path -split ';')) {
        $env:Path = "$ScoopShims;$env:Path"
    }
}

# ---------------------------------------------------------------------------
# 4) scoopfile.json (optional — exported with `cargo make scoop-export`)
# ---------------------------------------------------------------------------
$ScoopFile = Join-Path $DotfilesDir 'scoopfile.json'
if (Test-Path $ScoopFile) {
    Write-Step "Importing extras from $ScoopFile"
    try {
        scoop import $ScoopFile
    } catch {
        Write-Warn2 "scoop import failed: $_"
    }
}

# ---------------------------------------------------------------------------
# 4b) winget apps (not carried in the scoop set)
#     PowerToys + Coreutils ship via winget (App Installer, preinstalled on
#     Windows 11). Microsoft.Coreutils is MS's port of GNU coreutils:
#     https://github.com/microsoft/coreutils
# ---------------------------------------------------------------------------
if (Test-Cmd winget) {
    Write-Step 'Installing winget apps'
    $WingetApps = @(
        'Microsoft.PowerToys',
        'Microsoft.Coreutils',
        # Private networking for reaching services such as the PostgreSQL host
        # without exposing their ports to the public internet.
        'Tailscale.Tailscale',
        # Screenshot / OCR / pin-to-screen tool.
        'PixPin.PixPin'
    )
    foreach ($id in $WingetApps) {
        $installed = winget list --id $id --source winget --accept-source-agreements 2>$null |
            Select-String -SimpleMatch $id -Quiet
        if ($installed) {
            Write-Host "  $id already installed"
        } else {
            winget install --id $id --source winget --silent `
                --accept-package-agreements --accept-source-agreements
            if ($LASTEXITCODE -ne 0) { Write-Warn2 "  failed: $id" }
        }
    }
} else {
    Write-Warn2 'winget not on PATH -- skipping winget apps (install "App Installer" from the Microsoft Store)'
}

# The Desktop app's uninstall registration (DisplayName/DisplayVersion/InstallLocation),
# shared by the install/update step here and the plugin step that manages its profile.
function Get-DshDesktopUninstallRecord {
    Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'DeepSeek Harness *' -and $_.InstallLocation } |
        Select-Object -First 1
}

# DeepSeek Harness Desktop ships separately from the npm CLI. Use its official
# update feed so repeated runs download only a newer installer.
Write-Step 'Installing/updating DeepSeek Harness Desktop'
$DesktopFeedUrl = 'https://download.deepseek.com/dsh-desk/feeds/win-x64/nightly.yml'
try {
    $DesktopFeedResponse = Invoke-WebRequest -Uri $DesktopFeedUrl -UseBasicParsing -ErrorAction Stop
    $DesktopFeed = if ($DesktopFeedResponse.Content -is [byte[]]) {
        [Text.Encoding]::UTF8.GetString($DesktopFeedResponse.Content)
    } else { [string]$DesktopFeedResponse.Content }
    $DesktopVersionMatch = [regex]::Match($DesktopFeed, '(?m)^version: ([^\r\n]+)')
    $DesktopUrlMatch = [regex]::Match($DesktopFeed, '(?m)^path: >-\r?\n[ \t]+(https://download\.deepseek\.com/dsh-desk/bin/win-x64/[^\r\n ]+\.exe)\r?$')
    $DesktopHashMatch = [regex]::Match($DesktopFeed, '(?m)^sha512: >-\r?\n[ \t]+([A-Za-z0-9+/=]+)\r?$')
    if (-not ($DesktopVersionMatch.Success -and $DesktopUrlMatch.Success -and $DesktopHashMatch.Success)) {
        throw 'official update feed has an unexpected format'
    }
    $DesktopVersion = $DesktopVersionMatch.Groups[1].Value.Trim()
    $DesktopUrl = $DesktopUrlMatch.Groups[1].Value
    $DesktopHash = $DesktopHashMatch.Groups[1].Value
    $DesktopRecord = Get-DshDesktopUninstallRecord
    $DesktopInstalledVersion = if ($DesktopRecord) { $DesktopRecord.DisplayVersion } else { $null }
    if (-not $DesktopInstalledVersion -and $DesktopRecord) {
        $DesktopExe = Join-Path $DesktopRecord.InstallLocation 'DeepSeek Harness.exe'
        if (Test-Path $DesktopExe) { $DesktopInstalledVersion = (Get-Item $DesktopExe).VersionInfo.FileVersion }
    }
    if ($DesktopInstalledVersion -and -not (Test-SemverLt $DesktopInstalledVersion $DesktopVersion)) {
        Write-Host "  DeepSeek Harness Desktop @ $DesktopInstalledVersion is up to date"
    } elseif (Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue) {
        Write-Warn2 '  Quit DeepSeek Harness Desktop before installing/updating, then re-run this script'
    } else {
        $DesktopInstaller = Join-Path $env:TEMP "deepseek-harness-$([guid]::NewGuid()).exe"
        try {
            Write-Step "Downloading DeepSeek Harness Desktop $DesktopVersion"
            Invoke-WebRequest -Uri $DesktopUrl -UseBasicParsing -OutFile $DesktopInstaller -ErrorAction Stop
            $DesktopStream = [IO.File]::OpenRead($DesktopInstaller)
            $DesktopHasher = [Security.Cryptography.SHA512]::Create()
            try {
                $DesktopActualHash = [Convert]::ToBase64String($DesktopHasher.ComputeHash($DesktopStream))
            } finally { $DesktopStream.Dispose(); $DesktopHasher.Dispose() }
            if ($DesktopActualHash -ne $DesktopHash) { throw 'installer SHA-512 does not match the official update feed' }
            $DesktopProcess = Start-Process -FilePath $DesktopInstaller -ArgumentList '/S' -Wait -PassThru -WindowStyle Hidden
            if ($DesktopProcess.ExitCode -ne 0) { throw "installer exited with code $($DesktopProcess.ExitCode)" }
            $DesktopInstalled = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like 'DeepSeek Harness *' -and $_.DisplayVersion -eq $DesktopVersion } | Select-Object -First 1
            if (-not $DesktopInstalled) { throw 'installer completed but the expected version was not registered' }
            Write-Host "  DeepSeek Harness Desktop $DesktopVersion installed"
            if (-not (Test-Path (Join-Path $DshHome 'profiles\desktop\package.json'))) {
                Write-Host '  Launch Desktop once to initialize its profile, then re-run this script to install its plugin bundles and skills'
            }
        } finally {
            Remove-Item -LiteralPath $DesktopInstaller -Force -ErrorAction SilentlyContinue
        }
    }
} catch {
    Write-Warn2 "  DeepSeek Harness Desktop install/update failed: $_"
}

# Tailscale — installed via winget; ensure the daemon service is running and
# authenticate if this machine hasn't logged in yet.
$tailscaleCommand = Get-Command tailscale.exe -ErrorAction SilentlyContinue
$tailscaleExe = if ($tailscaleCommand) {
    $tailscaleCommand.Source
} else {
    Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
}
if (Test-Path -LiteralPath $tailscaleExe) {
    $tsSvc = Get-Service -Name 'Tailscale' -ErrorAction SilentlyContinue
    if (-not $tsSvc) { $tsSvc = Get-Service -Name 'tailscaled' -ErrorAction SilentlyContinue }
    if ($tsSvc -and $tsSvc.Status -ne 'Running') {
        Start-Service -Name $tsSvc.Name -ErrorAction SilentlyContinue
    }
    & $tailscaleExe status *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Host '  Tailscale already up'
    } else {
        Write-Host '  Logging in to Tailscale — complete browser auth when prompted'
        & $tailscaleExe up
        if ($LASTEXITCODE -ne 0) { Write-Warn2 '  tailscale up failed (run it manually)' }
    }
} else {
    Write-Warn2 'tailscale.exe not found — Tailscale may not have installed via winget'
}

# ---------------------------------------------------------------------------
# 4d) Visual Studio Build Tools — C++ compiler, MSBuild, CMake, headers.
#     Needed by: Neovim Telescope FZF Native (requires gcc/cl), Windows
#     Cargo builds (cc crate), Python native extensions, Windows SDK.
#     Installed via the VS Bootstrapper; only downloads what's needed.
#     Workload: VCTools (Desktop development with C++).
#     Idempotent: `vswhere` detects existing installs.
# ---------------------------------------------------------------------------
$VSBootstrapUrl = 'https://aka.ms/vs/17/release/vs_BuildTools.exe'
$VSBootstrapExe = Join-Path $env:TEMP 'vs_BuildTools.exe'
$VsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"

# Check if Build Tools are already installed by looking for vswhere or any
# instance with the VCTools workload.
#
# Query a plain ASCII property instead of `-format json`: PowerShell decodes a
# native command's stdout with the console code page it cached at startup, while
# vswhere writes UTF-8. Once anything earlier in this script changes the console
# code page the CJK display name/description get mis-decoded, the mangled bytes
# swallow the closing quote and ConvertFrom-Json dies ("unexpected character
# encountered ... line 17"), which silently fell through to reinstalling the
# whole multi-minute workload on every run. 7-bit ASCII decodes identically
# under every code page, so installationPath is encoding-proof.
$VsFound = $false
if (Test-Path $VsWhere) {
    $vsPath = @(& $VsWhere -latest -products '*' -requires 'Microsoft.VisualStudio.Workload.VCTools' -property installationPath 2>$null)
    if ($vsPath.Count -gt 0 -and $vsPath[0]) {
        Write-Step "Visual Studio Build Tools already installed: $($vsPath[0])"
        $VsFound = $true
    }
}

if (-not $VsFound) {
    Write-Step 'Installing Visual Studio Build Tools (C++ workloads)'
    try {
        Invoke-WebRequest -Uri $VSBootstrapUrl -OutFile $VSBootstrapExe -UseBasicParsing
        Write-Host '  Download complete, running installer (this may take several minutes)...'

        $proc = Start-Process -FilePath $VSBootstrapExe -ArgumentList @(
            '--quiet', '--wait', '--norestart', '--nocache',
            '--add', 'Microsoft.VisualStudio.Workload.VCTools',
            '--add', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
            '--add', 'Microsoft.VisualStudio.Component.Windows11SDK.22621',
            '--includeRecommended'
        ) -NoNewWindow -PassThru -Wait

        if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
            Write-Host "  VS Build Tools installed (exit code: $($proc.ExitCode) — 3010 = reboot recommended)"
        } else {
            Write-Warn2 "  VS Build Tools installer exited with code $($proc.ExitCode) — re-run manually if needed"
        }
    } catch {
        Write-Warn2 "  VS Build Tools install failed: $_"
    }
    Remove-Item $VSBootstrapExe -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# 5) Rust toolchain (rustup-init silent install)
# ---------------------------------------------------------------------------
if (-not (Test-Cmd rustup)) {
    Write-Step 'Installing Rust toolchain (silent)'
    $rustupInit = Join-Path $env:TEMP 'rustup-init.exe'
    Invoke-WebRequest -Uri 'https://win.rustup.rs/x86_64' -OutFile $rustupInit -UseBasicParsing
    & $rustupInit -y --no-modify-path --default-toolchain stable
    Remove-Item $rustupInit -ErrorAction SilentlyContinue
    $env:PATH = "$env:USERPROFILE\.cargo\bin;$env:PATH"
}
if (Test-Cmd rustup) {
    $installedComponents = rustup component list --installed 2>$null
    foreach ($c in @('clippy', 'rustfmt')) {
        if ($installedComponents | Select-String -SimpleMatch -Pattern $c -Quiet) {
            Write-Host "  rustup component $c already installed"
        } else {
            rustup component add $c 2>$null | Out-Null
        }
    }
}

# Always ensure ~/.cargo/bin is on session PATH — the rustup install block above
# only sets it when rustup is freshly installed; re-runs need it too for the
# cargo tools and dotter sections that follow.
$CargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
if ((Test-Path $CargoBin) -and ($CargoBin -notin ($env:Path -split ';'))) {
    $env:Path = "$CargoBin;$env:Path"
}

# ---------------------------------------------------------------------------
# 6) Cargo tools
# ---------------------------------------------------------------------------
Write-Step 'Installing Cargo tools'
# Map crate name -> binary name to detect (some differ: bottom->btm, cargo-update->cargo-install-update).
$CargoTools = [ordered]@{
    'dotter'       = 'dotter'
    'cargo-update' = 'cargo-install-update'
    'vivid'        = 'vivid'
    'eza'          = 'eza'
    'bottom'       = 'btm'
    'bat'          = 'bat'
    'mise'         = 'mise'
    'yazi-fm'      = 'yazi'
    'yazi-cli'     = 'ya'
    'pstop'        = 'pstop'
    'psnet'        = 'psnet'
    'abtop'        = 'abtop'
    'rmux'         = 'rmux'
}
foreach ($t in $CargoTools.Keys) {
    $bin = $CargoTools[$t]
    if (Test-Cmd $bin) {
        Write-Host "  $t already installed ($bin on PATH)"
        continue
    }
    Write-Host "  installing $t ..."
    cargo install $t
    if ($LASTEXITCODE -ne 0) {
        Write-Warn2 "  failed: $t (cargo exit code: $LASTEXITCODE)"
        continue
    }
    # Verify: cargo may report success but fail to produce the binary (e.g. linker
    # errors, missing native deps). Check that the exe actually landed.
    $binPath = Join-Path $CargoBin "$bin.exe"
    if (-not (Test-Path $binPath)) {
        Write-Warn2 "  ${t}: cargo reported OK but $bin.exe not found in $CargoBin — check cargo output above for linker / build errors"
    } else {
        Write-Host "    -> $binPath"
    }
}

# psmux - native-Windows terminal multiplexer, deliberately outside the
# skip-if-present loop above: bmad-loop's Windows backend needs psmux >= 3.4.0
# and tracks the newest release, so install it when missing and upgrade it when
# crates.io is ahead (plain `cargo install` never upgrades an existing binary).
$PsmuxFloor = [version]'3.4.0'
function Get-PsmuxVersion {
    if (-not (Test-Cmd psmux)) { return $null }
    $raw = psmux -V 2>$null | Select-Object -First 1
    if ($raw -match '(\d+\.\d+\.\d+)') { return [version]$Matches[1] }
    return $null
}
$psmuxInstalled = Get-PsmuxVersion
$psmuxLatest = $null
try {
    $psmuxCrate = Invoke-RestMethod -Uri 'https://crates.io/api/v1/crates/psmux' `
        -Headers @{ 'User-Agent' = 'dotfiles-install-windows' } -TimeoutSec 20 -ErrorAction Stop
    $psmuxLatestRaw = $null
    if ($psmuxCrate.crate.PSObject.Properties['max_stable_version'] -and $psmuxCrate.crate.max_stable_version) {
        $psmuxLatestRaw = [string]$psmuxCrate.crate.max_stable_version
    } elseif ($psmuxCrate.crate.PSObject.Properties['max_version']) {
        # No max_stable_version: only accept a plain release, never a pre-release.
        $psmuxMaxVersion = [string]$psmuxCrate.crate.max_version
        if ($psmuxMaxVersion -notmatch '-') { $psmuxLatestRaw = $psmuxMaxVersion }
    }
    if ($psmuxLatestRaw) { $psmuxLatest = [version]$psmuxLatestRaw }
} catch {
    # crates.io unreachable (offline / proxy): the 3.4.0 floor below still applies.
}
$psmuxTarget = $PsmuxFloor
if ($psmuxLatest -and $psmuxLatest -gt $psmuxTarget) { $psmuxTarget = $psmuxLatest }

if (-not $psmuxInstalled -or $psmuxInstalled -lt $psmuxTarget) {
    if (Test-Cmd cargo) {
        if (-not $psmuxInstalled) {
            Write-Step "Installing psmux (target >= $psmuxTarget)"
            cargo install psmux
        } else {
            Write-Step "Upgrading psmux: $psmuxInstalled -> $psmuxTarget"
            cargo install psmux --force
        }
    } else {
        Write-Warn2 "  cargo not on PATH - cannot install psmux (winget install psmux is the non-cargo fallback)"
    }
} else {
    Write-Host "  psmux already installed ($psmuxInstalled)"
}

# Re-read after the install so a failed upgrade is visible now, not on the
# first `bmad-loop run`.
$psmuxAfter = Get-PsmuxVersion
if (-not $psmuxAfter) {
    Write-Warn2 "  psmux not on PATH - bmad-loop's native Windows backend cannot drive runs"
} elseif ($psmuxAfter -lt $PsmuxFloor) {
    Write-Warn2 "  psmux $psmuxAfter is below the $PsmuxFloor floor bmad-loop requires"
} elseif ($psmuxLatest -and $psmuxAfter -lt $psmuxLatest) {
    Write-Warn2 "  psmux $psmuxAfter is older than $psmuxLatest on crates.io - upgrade failed?"
}
if (Test-Path (Join-Path $CargoBin 'psmux.exe')) { Write-Host "  -> $(Join-Path $CargoBin 'psmux.exe')" }

Write-Step 'Installing coreutils (windows feature)'
if (Test-Cmd coreutils) {
    Write-Host '  coreutils already installed'
} else {
    # `--features windows` pulls in stdbuf, which needs LIBSTDBUF_DIR
    # (a Unix LD_PRELOAD path) at compile time and won't build on Windows.
    # feat_Tier1 gives the same core utils without stdbuf.
    cargo install coreutils --no-default-features --features feat_Tier1
    if ($LASTEXITCODE -ne 0) { Write-Warn2 '  failed: coreutils' }
}

# ---------------------------------------------------------------------------
# 6b) PowerShell modules (PSGallery, current-user scope)
# ---------------------------------------------------------------------------
Write-Step 'Installing PowerShell modules from PSGallery'

# Bootstrap NuGet provider — required for first-time Install-Module.
if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
    Install-PackageProvider -Name NuGet -Scope CurrentUser -Force | Out-Null
}

# Trust PSGallery so Install-Module doesn't prompt.
if ((Get-PSRepository -Name PSGallery).InstallationPolicy -ne 'Trusted') {
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
}

$PsModules = @(
    'git-aliases',
    'Microsoft.WinGet.Client',
    'PSReadLine',
    'PSFzf',
    'z',
    'Terminal-Icons'
)
foreach ($m in $PsModules) {
    if (Get-Module -ListAvailable -Name $m) {
        Write-Host "  $m already installed"
    } else {
        Write-Host "  installing $m"
        Install-Module -Name $m -Scope CurrentUser -Force -AllowClobber -ErrorAction Continue
    }
}

# ---------------------------------------------------------------------------
# 6c) Wire $PROFILE to dotfiles PowerShell profile
#     Detects each host's actual profile path (handles OneDrive redirect).
# ---------------------------------------------------------------------------
$DotfilesProfile = Join-Path $DotfilesDir 'windows\powershell\Microsoft.PowerShell_profile.ps1'
if (Test-Path $DotfilesProfile) {
    Write-Step 'Wiring $PROFILE -> dotfiles powershell profile'
    $loader = ". `"$DotfilesProfile`""
    $shells = @()
    if (Test-Cmd powershell) { $shells += 'powershell' }
    if (Test-Cmd pwsh)       { $shells += 'pwsh' }
    foreach ($sh in $shells) {
        $pp = (& $sh -NoProfile -Command 'Write-Output $PROFILE.CurrentUserCurrentHost').Trim()
        if (-not $pp) { continue }
        $pdir = Split-Path -Parent $pp
        if (-not (Test-Path $pdir)) { New-Item -ItemType Directory -Path $pdir -Force | Out-Null }
        $existing = if (Test-Path $pp) { Get-Content $pp -Raw -ErrorAction SilentlyContinue } else { '' }
        if ($existing -and ($existing -match [regex]::Escape($DotfilesProfile))) {
            Write-Host "  $sh profile already wired"
        } else {
            Add-Content -Path $pp -Value $loader -Encoding UTF8
            Write-Host "  wired $sh profile: $pp"
        }
    }
}

# ---------------------------------------------------------------------------
# 7) uv (Python) + uv tools
# ---------------------------------------------------------------------------
if (-not (Test-Cmd uv)) {
    Write-Step 'Installing uv'
    Invoke-RestMethod -Uri 'https://astral.sh/uv/install.ps1' | Invoke-Expression
    $env:PATH = "$env:USERPROFILE\.local\bin;$env:PATH"
}
$UvFile = Join-Path $DotfilesDir 'uv-tools.txt'
if ((Test-Path $UvFile) -and (Test-Cmd uv)) {
    Write-Step "Installing uv tools from $UvFile"
    # Snapshot installed tools once -- avoids per-tool network call to PyPI.
    $installedUvTools = @(uv tool list 2>$null | ForEach-Object {
        # Lines look like "ruff v0.4.0" or indented "- ruff" entries; first token is the tool name.
        ($_ -split '\s+', 2)[0]
    } | Where-Object { $_ -and $_ -notmatch '^-' })
    Get-Content $UvFile | Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object {
        $tool = $_.Trim()
        if ($installedUvTools -contains $tool) {
            Write-Host "  $tool already installed"
        } else {
            uv tool install $tool 2>$null
            if ($LASTEXITCODE -ne 0) { Write-Warn2 "  skip $tool (already installed or failed)" }
        }
    }
}

# ---------------------------------------------------------------------------
# 7a-bis) Claude Code: defaultShell -> PowerShell (Windows only)
#     Windows-specific shell selection goes into settings.local.json (Claude
#     Code's machine-local overlay), kept separate from the generated
#     settings.json so it survives provider switches. Prefer pwsh (PowerShell
#     7+) when present,
#     fall back to Windows PowerShell 5.1.
# ---------------------------------------------------------------------------
Write-Step 'Configuring Claude Code defaultShell -> PowerShell'
$claudeDir = Join-Path $env:USERPROFILE '.claude'
if (-not (Test-Path $claudeDir)) { New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null }
$claudeLocal = Join-Path $claudeDir 'settings.local.json'
$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
if ($pwshCmd) {
    $shellPath = $pwshCmd.Source
} else {
    $shellPath = (Get-Command powershell -ErrorAction SilentlyContinue).Source
}
if ($shellPath) {
    $localObj = if (Test-Path $claudeLocal) {
        try { Get-Content $claudeLocal -Raw | ConvertFrom-Json } catch { [pscustomobject]@{} }
    } else { [pscustomobject]@{} }
    if (-not $localObj) { $localObj = [pscustomobject]@{} }
    $current = $localObj.PSObject.Properties['defaultShell']
    if ($current -and $current.Value -eq $shellPath) {
        Write-Host "  defaultShell already set to $shellPath"
    } else {
        if ($current) {
            $localObj.defaultShell = $shellPath
        } else {
            $localObj | Add-Member -NotePropertyName defaultShell -NotePropertyValue $shellPath -Force
        }
        ($localObj | ConvertTo-Json -Depth 32) | Set-Content -Path $claudeLocal -Encoding UTF8
        Write-Host "  set defaultShell = $shellPath in $claudeLocal"
    }
} else {
    Write-Warn2 '  neither pwsh nor powershell found on PATH — skipped'
}

# ---------------------------------------------------------------------------
# 7b2) herdr — coding-agent runtime (background daemon that keeps terminals
#      alive for Claude Code / Codex / OpenCode etc. across sleep/network drops)
# ---------------------------------------------------------------------------
if (-not (Test-Cmd herdr)) {
    Write-Step 'Installing herdr (coding-agent runtime)'
    irm 'https://herdr.dev/install.ps1' | iex
    if (-not (Test-Cmd herdr)) { Write-Warn2 '  herdr install failed or herdr is not yet on PATH' }
} else {
    Write-Host '  herdr already installed'
}

# ---------------------------------------------------------------------------
# 7b3) omp — coding agent with the IDE wired in (Windows-native). bin: `omp`,
#      config under ~/.omp. Supersedes the retired Pi coding agent.
# ---------------------------------------------------------------------------
if (-not (Test-Cmd omp)) {
    Write-Step 'Installing omp (coding agent)'
    irm 'https://omp.sh/install.ps1' | iex
    if (-not (Test-Cmd omp)) { Write-Warn2 '  omp install failed or omp is not yet on PATH' }
} else {
    Write-Host '  omp already installed'
}

# ---------------------------------------------------------------------------
# 7c) Global npm tools (hostc — Cloudflare-Workers edge tunnel CLI)
# ---------------------------------------------------------------------------
if (Test-Cmd npm) {
    if (-not (Test-Cmd hostc)) {
        Write-Step 'Installing hostc (edge tunnel CLI) via npm'
        npm install -g hostc
        if ($LASTEXITCODE -ne 0) { Write-Warn2 '  hostc install failed' }
    }
    if (-not (Test-Cmd claude-mem)) {
        Write-Step 'Installing claude-mem via npm'
        npm install -g claude-mem
        if ($LASTEXITCODE -ne 0) { Write-Warn2 '  claude-mem install failed' }
    }
    if (-not (Test-Cmd agent-browser)) {
        Write-Step 'Installing agent-browser (browser automation for AI agents) via npm'
        npm install -g agent-browser
        if ($LASTEXITCODE -ne 0) { Write-Warn2 '  agent-browser install failed' }
    }
    # One-time Chromium download for agent-browser (idempotent — skips if already present)
    if (Test-Cmd agent-browser) {
        Write-Step 'agent-browser: downloading Chromium (one-time)'
        agent-browser install 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Warn2 '  agent-browser install (Chromium) failed' }
    }
    # puppeteer — browser automation library (includes Chromium). --ignore-scripts skips the
    # postinstall Chromium download (redundant: agent-browser above already ships Chromium).
    $puppeteerGlobal = Join-Path (npm root -g 2>$null) 'puppeteer'
    if (-not (Test-Path $puppeteerGlobal)) {
        Write-Step 'Installing puppeteer (browser automation) via npm'
        npm install -g puppeteer --ignore-scripts
        if ($LASTEXITCODE -ne 0) { Write-Warn2 '  puppeteer install failed' }
    } else {
        Write-Host '  puppeteer already installed'
    }
    # AI coding CLIs (Claude Code / Codex / OpenCode / Grok / DeepSeek Harness)
    # 只在未安装或远端有新版时才 npm install；已是最新则跳过，重跑脚本不再白升级。
    Install-NpmCliIfStale '@anthropic-ai/claude-code' 'Claude Code CLI'
    Install-NpmCliIfStale '@openai/codex' 'Codex CLI'
    # oh-my-codex — Yeachan-Heo multi-agent orchestration layer for Codex. bin: `omx`.
    Install-NpmCliIfStale 'oh-my-codex' 'oh-my-codex (omx CLI)'
    Install-NpmCliIfStale '@opencode/cli' 'OpenCode CLI'
    Install-NpmCliIfStale '@xai-official/grok' 'Grok CLI'
    # DeepSeek Harness — official DeepSeek native agent framework. bin: `dsh`,
    # profile/state under $DshHome\profiles. Node ^22.19 || >=24.
    Install-NpmCliIfStale '@deepseek-ai/dsh' 'DeepSeek Harness CLI'
    # dsh-tui — Claude Code-style interactive TUI front door for dsh. bin: `dsh-tui`.
    Install-NpmCliIfStale '@deepseek-harness-tui/dsh-tui' 'DeepSeek Harness TUI'
    # zg — zvec-grep: local-first search layer (ripgrep + BM25 + vector search)
    # for humans and agents. bin: `zg`. Requires Node.js >= 22.
    Install-NpmCliIfStale '@zvec/zvec-grep' 'zg (zvec-grep)'

    # Deploy Claude Code statusline / claude-hud helpers into ~/.claude/.
    # These were previously dotter-symlinked; now copied here so dotter no longer
    # manages coding-agent config. Generated settings.json (aicodingagentconfig.py)
    # points statusLine at ~/.claude/statusline.mjs, which spawns the
    # claude-hud-usage-refresh.mjs refresher and reads plugins/claude-hud/config.json.
    $claudeDeployDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
    $claudeDeploySrc = Join-Path $DotfilesDir 'common\claude'
    if (Test-Path $claudeDeploySrc) {
        Write-Step 'Deploying Claude Code statusline / claude-hud helpers'
        try {
            $hudPluginDir = Join-Path $claudeDeployDir 'plugins\claude-hud'
            New-Item -ItemType Directory -Path $hudPluginDir -Force | Out-Null
            Copy-Item -Path (Join-Path $claudeDeploySrc 'statusline.mjs') -Destination (Join-Path $claudeDeployDir 'statusline.mjs') -Force -ErrorAction Stop
            Copy-Item -Path (Join-Path $claudeDeploySrc 'claude-hud-usage-refresh.mjs') -Destination (Join-Path $claudeDeployDir 'claude-hud-usage-refresh.mjs') -Force -ErrorAction Stop
            Copy-Item -Path (Join-Path $claudeDeploySrc 'claude-hud-config.json') -Destination (Join-Path $hudPluginDir 'config.json') -Force -ErrorAction Stop
        } catch {
            Write-Warn2 "  claude helper deploy failed: $_"
        }
    }

    # Register upstash/context7 as an MCP server for Claude Code & Codex.
    # Idempotent: `mcp add` errors if already registered, which we swallow.
    if (Test-Cmd claude) {
        Write-Step 'Registering context7 MCP for Claude Code (idempotent)'
        claude mcp add context7 -s user -- npx -y '@upstash/context7-mcp' 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Host "  context7 MCP already registered for claude (or registration failed — see 'claude mcp list')" }
    }
    if (Test-Cmd codex) {
        Write-Step 'Registering context7 MCP for Codex (idempotent)'
        codex mcp add context7 -- npx -y '@upstash/context7-mcp' 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Host "  context7 MCP already registered for codex (or registration failed — see 'codex mcp list')" }
    }

    # Register chrome-devtools MCP (local stdio via npx) for Claude Code & Codex.
    # Drives a real Chrome via the DevTools Protocol; idempotent — `mcp add`
    # errors if already registered, which we swallow.
    # NOTE: on Windows `npx` is a `.cmd` shim and cannot be spawned directly —
    # it must be invoked through `cmd /c`, otherwise the spawn fails and the
    # server never connects (same wrapper the working context7/playwright use).
    # User scope so it is available in every project, not just the install cwd.
    if (Test-Cmd claude) {
        Write-Step 'Registering chrome-devtools MCP for Claude Code (idempotent)'
        claude mcp add chrome-devtools -s user -- cmd /c npx -y 'chrome-devtools-mcp@latest' 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Host "  chrome-devtools MCP already registered for claude (or registration failed — see 'claude mcp list')" }
    }
    if (Test-Cmd codex) {
        Write-Step 'Registering chrome-devtools MCP for Codex (idempotent)'
        codex mcp add chrome-devtools -- cmd /c npx -y 'chrome-devtools-mcp@latest' 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Host "  chrome-devtools MCP already registered for codex (or registration failed — see 'codex mcp list')" }
    }

    # Register zcaceres/fetch-mcp (local stdio via npx, package `mcp-fetch-server`)
    # for Claude Code & Codex. Fetches web content as HTML/markdown/text/JSON.
    # Same `cmd /c npx` wrapper as above; idempotent — `mcp add` errors if already
    # registered, which we swallow.
    if (Test-Cmd claude) {
        Write-Step 'Registering fetch MCP for Claude Code (idempotent)'
        claude mcp add fetch -s user -- cmd /c npx -y 'mcp-fetch-server' 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Host "  fetch MCP already registered for claude (or registration failed — see 'claude mcp list')" }
    }
    if (Test-Cmd codex) {
        Write-Step 'Registering fetch MCP for Codex (idempotent)'
        codex mcp add fetch -- cmd /c npx -y 'mcp-fetch-server' 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Host "  fetch MCP already registered for codex (or registration failed — see 'codex mcp list')" }
    }

    # Register GitHub's official remote MCP server (streamable HTTP). The endpoint
    # does NOT support OAuth dynamic client registration, so clients must auth with a
    # PAT in an Authorization header. Token source: GITHUB_PERSONAL_ACCESS_TOKEN /
    # GH_TOKEN env vars, then the gh CLI's stored token. Claude/Codex register via
    # their CLIs; opencode takes a JSON `mcp` entry.
    $GhMcpUrl = 'https://api.githubcopilot.com/mcp/'
    $GhMcpPat = $env:GITHUB_PERSONAL_ACCESS_TOKEN
    if (-not $GhMcpPat) { $GhMcpPat = $env:GH_TOKEN }
    if (-not $GhMcpPat -and (Test-Cmd gh)) { $GhMcpPat = (gh auth token 2>$null) }
    if (Test-Cmd claude) {
        claude mcp get github 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Step 'github MCP already registered for Claude Code (user scope)'
        } elseif ($GhMcpPat) {
            Write-Step 'Registering github MCP for Claude Code (remote HTTP, PAT header)'
            claude mcp add --transport http github $GhMcpUrl -H "Authorization: Bearer $GhMcpPat" -s user 2>$null
            if ($LASTEXITCODE -ne 0) { Write-Warn2 "  github MCP registration FAILED — run: claude mcp add --transport http github $GhMcpUrl -H `"Authorization: Bearer <PAT>`" -s user" }
        } else {
            Write-Warn2 '  no GitHub PAT found (set GITHUB_PERSONAL_ACCESS_TOKEN or run ''gh auth login'') -- skipping github MCP for Claude Code (remote endpoint OAuth/DCR is unsupported)'
        }
    }
    if (Test-Cmd codex) {
        Write-Step "Registering github MCP for Codex (remote HTTP; run 'codex mcp login github' to OAuth)"
        codex mcp add github --url $GhMcpUrl 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Host "  github MCP already registered for codex (or registration failed — see 'codex mcp list')" }
    }
    # opencode: merge an `mcp.servers.github` (remote) entry into its JSON
    # config idempotently. v2 nests MCP servers under mcp.servers (v1 put them
    # directly under mcp).
    if (Test-Cmd node) {
        function Register-JsonMcp([string]$File, [string]$AddJson) {
            $env:MCP_FILE = $File
            $env:MCP_ADD = $AddJson
            # Pass via stdin (single-quoted here-string) instead of `node -e`:
            # PowerShell 5.1 strips double quotes from native args, corrupting
            # `require("fs")` into `require(fs)`.
            $script = @'
const fs=require("fs"), path=require("path");
const f=process.env.MCP_FILE, add=JSON.parse(process.env.MCP_ADD);
let c={}; try{ c=JSON.parse(fs.readFileSync(f,"utf8")); }catch(e){}
c.mcp=(c.mcp&&typeof c.mcp==="object")?c.mcp:{};
c.mcp.servers=(c.mcp.servers&&typeof c.mcp.servers==="object")?c.mcp.servers:{};
let changed=false;
for(const [k,v] of Object.entries(add)){ if(!c.mcp.servers[k]){ c.mcp.servers[k]=v; changed=true; } }
if(changed){ fs.mkdirSync(path.dirname(f),{recursive:true}); fs.writeFileSync(f, JSON.stringify(c,null,2)+"\n"); }
'@
            $script | node -
            if ($LASTEXITCODE -ne 0) { Write-Warn2 "  failed to write MCP config to $File" }
            Remove-Item Env:MCP_FILE, Env:MCP_ADD -ErrorAction SilentlyContinue
        }
        # Build the github entry via ConvertTo-Json so a PAT containing quotes or
        # backslashes can't corrupt the JSON (hand-built strings would).
        $ghMcp = @{ github = @{ type = 'remote'; url = $GhMcpUrl; oauth = $false } }
        if ($GhMcpPat) { $ghMcp.github.headers = @{ Authorization = "Bearer $GhMcpPat" } }
        $GhRemoteJson = $ghMcp | ConvertTo-Json -Compress -Depth 5
        $CdtLocalJson = '{"chrome-devtools":{"type":"local","command":["npx","-y","chrome-devtools-mcp@latest"]}}'
        $FetchLocalJson = '{"fetch":{"type":"local","command":["npx","-y","mcp-fetch-server"],"timeout":{"startup":120000}}}'
        $Ctx7LocalJson = '{"context7":{"type":"local","command":["npx","-y","@upstash/context7-mcp"]}}'
        # zg (zvec-grep) — stdio bootstrap; starts/reuses the shared daemon.
        $ZvecLocalJson = '{"zvec_grep":{"type":"local","command":["zg","server","--stdio"],"timeout":600000}}'
        if (Test-Cmd opencode) {
            Write-Step 'Registering github + chrome-devtools + fetch + context7 + zvec_grep MCP for opencode (~/.config/opencode/opencode.json)'
            Register-JsonMcp "$HOME\.config\opencode\opencode.json" $GhRemoteJson
            Register-JsonMcp "$HOME\.config\opencode\opencode.json" $CdtLocalJson
            Register-JsonMcp "$HOME\.config\opencode\opencode.json" $FetchLocalJson
            Register-JsonMcp "$HOME\.config\opencode\opencode.json" $Ctx7LocalJson
            if (Test-Cmd zg) { Register-JsonMcp "$HOME\.config\opencode\opencode.json" $ZvecLocalJson }
        }
    }
} else {
    Write-Warn2 'npm not on PATH -- skipping npm-based CLI installs (open a new shell after scoop installs nodejs-lts, then re-run)'
}

# ---------------------------------------------------------------------------
# 7c) pnpm — standalone binary (dsh invokes `pnpm` to install profile plugins).
#     Avoid corepack: the corepack that ships with nodejs-lts can't run pnpm >= 10
#     (pnpm.cjs top-level dynamic import throws ERR_VM_DYNAMIC_IMPORT_CALLBACK_MISSING).
#     Gate on "can actually run", not Test-Cmd — a broken shim may already be on PATH.
# ---------------------------------------------------------------------------
if (Test-Cmd npm) {
    $pnpmOk = $false
    if (Test-Cmd pnpm) {
        pnpm --version *> $null
        if ($LASTEXITCODE -eq 0) { $pnpmOk = $true }
    }
    if (-not $pnpmOk) {
        Write-Step 'Installing standalone pnpm via npm'
        npm install -g pnpm
        if ($LASTEXITCODE -ne 0) { Write-Warn2 '  pnpm install failed' }
    }
} else {
    Write-Warn2 'npm not on PATH -- skipping pnpm install (open a new shell after scoop installs nodejs-lts, then re-run)'
}

# ---------------------------------------------------------------------------
# 7d) Yunxing plugin (raptoravis/yunxing)
#     Claude Code — marketplace name "yunxing" (derived from
#     .claude-plugin/marketplace.json), plugin selector "yunxing@yunxing".
#     Codex — marketplace name "yunxing", plugin selector "yunxing@yunxing"
#     (derived from .codex-plugin/plugin.json).
#     OpenCode — native plugin module via git URL.
# ---------------------------------------------------------------------------
# Claude Code — `claude plugin` CLI (declarative settings.json is the fallback).
if (Test-Cmd claude) {
    Write-Step 'Installing yunxing Claude Code plugin (marketplace: yunxing)'
    claude plugin marketplace add raptoravis/yunxing 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Warn2 '  claude marketplace add failed (may already be registered)' }
    claude plugin install yunxing@yunxing 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Warn2 '  claude plugin install failed (may already be enabled)' }
} else {
    Write-Warn2 'claude CLI not on PATH -- falling back to settings.json declaration (re-run after claude is installed)'
}

# Ensure a local yunxing checkout is up to date — it's the version reference for
# the Codex "reinstall only on a new version" check, and the source for the
# Cursor skills links below.
$YunxingSrc = Join-Path $env:USERPROFILE '.local\share\yunxing'
if (Test-Cmd git) {
    if (Test-Path (Join-Path $YunxingSrc '.git')) {
        Write-Step 'Updating yunxing checkout'
        git -C $YunxingSrc pull --ff-only --quiet 2>$null
        if ($LASTEXITCODE -ne 0) {
            # pull failed -- checkout has local changes or is corrupt; drop it and re-clone below.
            Write-Warn2 '  yunxing pull failed -- re-cloning'
            Remove-Item -Recurse -Force $YunxingSrc
        }
    }
    if (-not (Test-Path (Join-Path $YunxingSrc '.git'))) {
        Write-Step 'Cloning yunxing checkout'
        New-Item -ItemType Directory -Force -Path (Split-Path $YunxingSrc) | Out-Null
        git clone --depth=1 --quiet https://github.com/raptoravis/yunxing.git $YunxingSrc 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Warn2 '  yunxing clone failed' }
    }
} else {
    Write-Warn2 'git not on PATH -- skipping yunxing checkout (Cursor skills + Codex version check)'
}

if (Test-Cmd codex) {
    # Reinstall the Codex plugin only when yunxing has a new version: compare the
    # installed version (codex plugin list) against the checkout's plugin.json.
    $yunxingNewVer = $null
    if (Test-Path (Join-Path $YunxingSrc '.codex-plugin\plugin.json')) {
        $yunxingNewVer = (Get-Content (Join-Path $YunxingSrc '.codex-plugin\plugin.json') -Raw | ConvertFrom-Json).version
    }
    $installedVer = $null
    $listJson = codex plugin list --json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($listJson) {
        $yunxingInst = $listJson.installed | Where-Object { $_.name -eq 'yunxing' -and $_.marketplaceName -eq 'yunxing' }
        if ($yunxingInst) { $installedVer = $yunxingInst.version }
    }

    if (-not $yunxingNewVer) {
        Write-Warn2 '  could not resolve yunxing version; skipping Codex plugin install'
    } elseif ($installedVer -and $installedVer -eq $yunxingNewVer) {
        Write-Host "  yunxing Codex plugin already up to date ($installedVer)"
    } else {
        if ($installedVer) {
            Write-Step "Updating yunxing Codex plugin ($installedVer -> $yunxingNewVer)"
        } else {
            Write-Step 'Installing yunxing Codex plugin (marketplace: yunxing)'
        }
        codex plugin marketplace add raptoravis/yunxing 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Warn2 '  codex marketplace add failed' }

        # `codex plugin marketplace upgrade` renames the old checkout out of the way, and
        # `codex plugin add` renames the old cache entry to back it up — both renames are
        # denied (os error 5) on Windows for git checkouts. Refresh the marketplace
        # snapshot with an in-place `git pull` (no rename; `marketplace add` above already
        # cloned it on a fresh machine) and delete the stale cache (re-downloadable).
        $YunxingMp = Join-Path $CodexHome '.tmp\marketplaces\yunxing'
        if ((Test-Cmd git) -and (Test-Path (Join-Path $YunxingMp '.git'))) {
            git -C $YunxingMp pull --ff-only --quiet 2>$null
        }
        Remove-Item -Recurse -Force (Join-Path $CodexHome 'plugins\cache\yunxing') -ErrorAction SilentlyContinue

        # Capture stderr so a real error is distinguishable from the rename denial above.
        # `os error 5` is locale-independent; the localized message is not.
        $codexErr = (codex plugin add yunxing@yunxing 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            if ($codexErr -match 'os error 5|Access denied|Access is denied') {
                Write-Warn2 '  codex plugin add failed: os error 5 renaming plugin cache (close codex, then re-run)'
            } elseif ($codexErr) {
                Write-Warn2 "  codex plugin add failed: $codexErr"
            } else {
                Write-Warn2 '  codex plugin add failed'
            }
        }
    }
} else {
    Write-Warn2 'codex CLI not on PATH -- skipping Codex plugin install (re-run after codex is installed)'
}

# OpenCode — native plugin module (one-step; no marketplace concept).
if (Test-Cmd opencode) {
    Write-Step 'Installing yunxing OpenCode plugin'
    # Strip opencode v1's singular `plugin` key and any pinned `#hash` yunxing
    # entry from `plugins`. `opencode plugin remove` only reads the plural key, and
    # the pinned commit lacks a default export, so it breaks `plugin check`/`update`
    # iteration; a pinned spec also makes `plugin add` accumulate duplicates.
    $ocCfgPath = Join-Path $env:USERPROFILE '.config\opencode\opencode.json'
    if ((Test-Cmd node) -and (Test-Path $ocCfgPath)) {
        $env:OC_CFG = $ocCfgPath
        $ocCleanup = @'
const fs=require("fs");
let c; try{ c=JSON.parse(fs.readFileSync(process.env.OC_CFG,"utf8")); }catch(e){ process.exit(0); }
if(!c || typeof c!=="object") process.exit(0);
let changed=false;
if(Object.prototype.hasOwnProperty.call(c,"plugin")){ delete c.plugin; changed=true; }
if(Array.isArray(c.plugins)){
  const next=[...new Set(c.plugins.filter(s=>!(typeof s==="string"&&s.startsWith("yunxing")&&s.includes("#"))))];
  if(next.length!==c.plugins.length){ c.plugins=next; changed=true; }
}
if(changed){ fs.writeFileSync(process.env.OC_CFG, JSON.stringify(c,null,2)+"\n"); console.error("==> cleaned legacy/pinned opencode plugin entries"); }
'@
        $ocCleanup | node -
        if ($LASTEXITCODE -ne 0) { Write-Warn2 '  failed to clean legacy opencode plugin entries' }
        Remove-Item Env:OC_CFG -ErrorAction SilentlyContinue
    }
    # Unpinned spec: `add` is idempotent only for an exact match — the cleanup above
    # strips pinned `#hash` entries so `add` won't accumulate duplicates. Upgrades go
    # through `plugin update` with no target (updates all outdated plugins), which
    # never fails with "not configured" on a spec mismatch.
    $ocErr = (opencode plugin add "yunxing@git+https://github.com/raptoravis/yunxing.git" 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        if ($ocErr) { Write-Warn2 "  opencode plugin add failed: $ocErr" }
        else { Write-Warn2 '  opencode plugin add failed' }
    }
    $ocErr = (opencode plugin update 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        if ($ocErr) { Write-Warn2 "  opencode plugin update failed: $ocErr" }
        else { Write-Warn2 '  opencode plugin update failed' }
    }
} else {
    Write-Warn2 'opencode CLI not on PATH -- skipping OpenCode plugin install (re-run after opencode is installed)'
}

# oh-my-claudecode + oh-my-codex (Yeachan-Heo)
#   oh-my-claudecode — Claude Code multi-agent plugin. Marketplace name "omc",
#   plugin selector "oh-my-claudecode@omc"; same install shape as yunxing.
#   oh-my-codex — Codex orchestration layer. The npm package (installed above)
#   ships the `omx` CLI; `omx setup --scope user` wires the plugin + hooks into
#   the user's codex config (idempotent; re-run keeps it current).
# Claude Code — oh-my-claudecode plugin.
if (Test-Cmd claude) {
    Write-Step 'Installing oh-my-claudecode Claude Code plugin (marketplace: omc)'
    claude plugin marketplace add Yeachan-Heo/oh-my-claudecode 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Warn2 '  claude marketplace add oh-my-claudecode failed (may already be registered)' }
    claude plugin marketplace update omc 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Warn2 '  claude marketplace update omc failed' }
    if (claude plugin list 2>$null | Select-String -Quiet 'oh-my-claudecode@omc') {
        claude plugin update oh-my-claudecode@omc 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Warn2 '  claude plugin update oh-my-claudecode failed' }
    } else {
        claude plugin install oh-my-claudecode@omc 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Warn2 '  claude plugin install oh-my-claudecode failed (may already be enabled)' }
    }
} else {
    Write-Warn2 'claude CLI not on PATH -- skipping oh-my-claudecode (re-run after claude is installed)'
}

# Wire zg into supported AI agents via MCP (managed zvec_grep entry + search
# guidance + tool approval + start local server). Idempotent — re-runs update
# only the ZVEC_GREP_START/END managed blocks; --force absorbs any stray
# unmanaged zvec_grep table. dsh / omp / grok are not supported zg targets and
# skipped. opencode is wired manually above.
#
# MUST run after the codex MCP/plugin registration above and before `omx setup`
# below: `codex mcp add` re-serializes config.toml and drops trailing comment
# markers, so zg's block (appended at EOF) would otherwise clobber the OMX hook
# trust END marker and make `omx setup` refuse to reconcile its trust state.
# Running zg here lets `omx setup` regenerate its block and re-serialize cleanly,
# absorbing zg's markers.
if (Test-Cmd zg) {
    $zgTargets = @('cursor')  # GUI IDE, no CLI to detect — always wire
    foreach ($t in @('claude', 'codex')) {
        if (Test-Cmd $t) { $zgTargets += $t }
    }
    $zgArgs = @('--force')
    foreach ($t in $zgTargets) { $zgArgs += '--target'; $zgArgs += $t }
    Write-Step "Wiring zg MCP into AI agents ($($zgTargets -join ', '))"
    $zgOutput = & zg install @zgArgs --yes 2>&1
    $zgExitCode = $LASTEXITCODE
    $zgText = ($zgOutput | Out-String).TrimEnd()
    if ($zgText) { Write-Host $zgText }
    if ($zgExitCode -ne 0) {
        if ($zgText -match 'EADDRINUSE') {
            Write-Step '  zg server start skipped: port already in use (an existing or legacy server may be running; see zg output above)'
        } elseif ($zgText -match 'conflicting|unmanaged') {
            Write-Warn2 '  zg install failed: MCP config conflict needs cleanup (see zg output above)'
        } else {
            Write-Warn2 '  zg install failed (see zg output above)'
        }
    }
}

# Codex — oh-my-codex. `omx setup --scope user` wires the plugin + hooks into the
# user's codex config (idempotent; re-run keeps it current).
#
# stdin + stdout are detached from the console because `omx setup` only prompts
# when BOTH are terminals (persisted-preference review, legacy vs plugin skill
# delivery). Detached, it reuses the choices recorded in .\.omx\setup-scope.json,
# so an existing install is kept as-is instead of blocking on a prompt the
# suppression below would hide.
if ((Test-Cmd codex) -and (Test-Cmd omx)) {
    Write-Step 'Wiring oh-my-codex into Codex (omx setup --scope user; keeping recorded choices)'
    $omxErr = ($null | omx setup --scope user 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        if ($omxErr) { Write-Warn2 "  omx setup --scope user failed: $omxErr" }
        else { Write-Warn2 '  omx setup --scope user failed' }
    }
} else {
    Write-Warn2 'codex/omx not on PATH -- skipping oh-my-codex setup (re-run after oh-my-codex is installed)'
}

# dsh — DeepSeek Harness plugins (package.json dsh.bundle → cordis.patch.yml).
# dshmarket: in-harness plugin marketplace; dsh-context: context insight panel;
# dsh-browser-use: Browser Use Cloud bridge (removed; no 0.2.0-rc-compatible release);
# yunxing: local skill bundle via GitHub shorthand; modlens: vision/tools bundle
# (image → structured JSON evidence); dsh-agent-teams: multi-agent team
# collaboration tools + web tree monitor (@nanmicoder/dsh-agent-teams);
# dsh-engineering-skill-pack: 28 engineering/stack/UI/writing skills in one bundle.
# dsh-mnemon: composable view-based context/memory; dsh-image-gen: image generation
# (Gemini/OpenAI/Seedream/DashScope/ComfyUI).
# ds-bot: DS Bot — long-lived bots, a main bot, Bot-to-Bot messages and group
# chats (npm `ds-bot`, https://github.com/Fei2411/DeepSeek-Bot). Its client
# platform is `web`, so it is installed with the web/UI plugins below, not into
# every profile. `dsh-bot` is a different package (dushaobindoudou/dsh-plugin:
# a headless cron/webhook runner) that an earlier run installed by mistake; it
# is removed below where present.
# dsh-skills-manager + dsh-im dropped: they pin @deepseek-ai/*@^0.1.x-rc and are
# rejected by dsh 0.2.x (install refused; `allow-version --accept-risk` required).
# Re-add once upstream ships 0.2.x-compatible releases.
# The filesystem skill provider (@deepseek-ai/dsh-skill-filesystem) that reads
# ~\.dsh\skills is already built into dsh via @deepseek-ai/dsh-base, so it is
# not added here (its npm `latest` is a stale 0.0.1-rc.3 library, not a bundle).
# Each bundle is installed if absent and updated to latest if present.
#
# Profiles install per directory, so a profile booted without these skill bundles
# composes no yunxing/modlens skill provider and its sessions list no yunxing or
# modlens skills. The bundles therefore go into EVERY profile already on disk — the
# earlier `web`-only loop left the TUI profile, the everyday entry point, skill-less.
# Re-run after creating a new profile. The web/UI plugins stay on `web`.
#
# The Electron Desktop profile gets the same six bundles below, managed with the
# `dsh plugin` command inside the app bundle so it works even without an npm dsh CLI.
# That runtime is the nightly build and can run ahead of the npm CLI, so its plugin
# manager refuses a bundle whose engines.dsh / @deepseek-ai peer ranges exclude it;
# the refusal reason is reported and the bundle is skipped (re-run after it ships a
# compatible release). Desktop shares ~\.dsh\skills through dsh-base, so the 7e2/7e3
# links cover its filesystem skills too.
#
# dsh-tui is the exception: its profile is bootstrapped lazily by the launcher on
# first `dst` run, so it isn't on disk when this loop scans. Pre-install the skill
# bundles into it explicitly, or the TUI boots skill-less until the next re-run.
function Get-DshPluginName ([string]$Spec) {
    if ($Spec -like 'github:*') { return ($Spec -split '/')[-1] }
    return $Spec
}

# Surface the plugin manager's rejection reason (e.g. a bundle whose dsh peer
# ranges exclude the Desktop app's nightly runtime) instead of only a bare warning.
function Show-DshPluginFailure ($Output) {
    $Reason = $Output | Select-String -Pattern 'installation rejected|incompatible with dsh|plugin command failed|ERR_PNPM_|error:' |
        Select-Object -First 1
    if (-not $Reason) { return }
    # The compatibility diagnostic repeats every peer range; keep only its verdict.
    $Text = $Reason.Line -replace ': requirements \{.*$', ''
    if ($Text.Length -gt 220) { $Text = $Text.Substring(0, 220) }
    Write-Host "    $Text"
}

# Install a plugin if absent, otherwise update it to latest. `dsh plugin add`
# delegates to pnpm add — fine for registry specs, but git specs pin a commit and
# re-adding retains that lock, so present plugins always go through
# `dsh plugin update <name> --latest`. Output is captured so a refused bundle can
# report the manager's reason without flooding the log with pnpm progress.
function Install-OrUpdate-DshPlugin ([string]$Profile, [string]$Spec, [string]$DshCommand = 'dsh') {
    $Name = Get-DshPluginName $Spec
    if (& $DshCommand plugin --profile $Profile list 2>$null | Select-String -SimpleMatch -Quiet "$Name@") {
        Write-Step "Updating dsh plugin: $Spec (profile: $Profile)"
        $Output = & $DshCommand plugin --profile $Profile update $Name --latest 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warn2 "  dsh plugin update $Name failed on $Profile"
            Show-DshPluginFailure $Output
        }
    } else {
        Write-Step "Installing dsh plugin: $Spec (profile: $Profile)"
        $Output = & $DshCommand plugin --profile $Profile add $Spec 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warn2 "  dsh plugin add $Spec failed on $Profile"
            Show-DshPluginFailure $Output
        }
    }
}

# pnpm prints "Issues with peer dependencies found" after every plugin operation
# because each profile sets autoInstallPeers: false: an out-of-tree bundle
# declares the host runtime (@deepseek-ai/*) and React as peers, and the running
# dsh supplies both from its own module tree, so pnpm can never resolve them
# inside the profile. Record that as expected in the profile's pnpm settings so
# `dsh plugin` runs stop flagging it. Nothing real is hidden: dsh's own startup
# check (engines.dsh / @deepseek-ai peer ranges) still refuses an incompatible
# bundle, as it did for dsh-builtin-browser 0.1.22 on dsh 0.2.x.
# peerDependencyRules survives later plugin operations — the plugin manager edits
# pnpm-workspace.yaml key by key and never regenerates the file.
function Set-DshProfilePeerRules ([string]$Profile) {
    $Workspace = Join-Path $DshHome "profiles\$Profile\pnpm-workspace.yaml"
    if (-not (Test-Path $Workspace)) { return }
    $Content = (Get-Content $Workspace -Raw).TrimEnd()
    if ($Content -match '(?m)^peerDependencyRules:') { return }
    $Rules = @(
        'peerDependencyRules:'
        '  ignoreMissing:'
        "    - '@deepseek-ai/*'"
        '    - react'
        '    - react-dom'
    )
    # dsh-tui renders with React 19 while dsh-working-activity, its own
    # dependency, still declares React 18; allow the installed major instead of
    # forcing a second React copy into the profile.
    $ReactManifest = Join-Path $DshHome "profiles\$Profile\node_modules\react\package.json"
    if (Test-Path $ReactManifest) {
        $ReactMajor = (Get-Content $ReactManifest -Raw | ConvertFrom-Json).version.Split('.')[0]
        $Rules += @('  allowedVersions:', "    'dsh-working-activity>react': '^$ReactMajor'")
    }
    Set-Content -Path $Workspace -Value ($Content + "`n`n" + ($Rules -join "`n") + "`n") -NoNewline
}

# Skill/tool bundles for every profile that can compose them: each CLI profile and
# the Electron Desktop profile (managed outside the npm-dsh gate further below).
# dsh-tui is pre-installed explicitly because the launcher creates its profile
# lazily on first `dst` run.
$DshBundles = @('github:raptoravis/yunxing', '@liustack/modlens', '@nanmicoder/dsh-agent-teams', 'github:lcx9451/dsh-engineering-skill-pack', 'dsh-mnemon', 'dsh-image-gen')

if (Test-Cmd dsh) {
    # CLI profiles keep their own skill/tool bundles; Desktop is handled below.
    $DshProfilesSeen = 0
    $DshTuiCovered = $false
    foreach ($DshProfileDir in (Get-ChildItem (Join-Path $DshHome 'profiles') -Directory -ErrorAction SilentlyContinue)) {
        if (-not (Test-Path (Join-Path $DshProfileDir.FullName 'package.json'))) { continue }
        # The npm CLI rejects the Electron-owned desktop profile. Its bundled
        # command handles that profile below using the Desktop installation runtime.
        if ($DshProfileDir.Name -eq 'desktop') { continue }
        $DshProfilesSeen++
        if ($DshProfileDir.Name -eq 'dsh-tui') { $DshTuiCovered = $true }
        Set-DshProfilePeerRules $DshProfileDir.Name
        foreach ($DshBundle in $DshBundles) {
            Install-OrUpdate-DshPlugin $DshProfileDir.Name $DshBundle
        }
    }
    if ($DshProfilesSeen -eq 0) {
        # Fresh machine: no profile on disk yet — the plugin manager creates `web` on demand.
        foreach ($DshBundle in $DshBundles) {
            Install-OrUpdate-DshPlugin 'web' $DshBundle
        }
        Set-DshProfilePeerRules 'web'
    }
    if (-not $DshTuiCovered) {
        foreach ($DshBundle in $DshBundles) {
            Install-OrUpdate-DshPlugin 'dsh-tui' $DshBundle
        }
        Set-DshProfilePeerRules 'dsh-tui'
    }

    foreach ($plugin in @('dshmarket', 'dsh-context', 'ds-bot')) {
        Install-OrUpdate-DshPlugin 'web' $plugin
    }

    # dsh-browser-use (Browser Use Cloud bridge) has no release compatible with
    # dsh 0.2.0-rc — its peer @deepseek-ai/dsh-tools ^0.1.0-rc.6 pins it to 0.1.x.
    # Drop it so the web profile isn't denied at startup; re-add once upstream
    # ships a 0.2.0-rc-compatible build.
    if (dsh plugin --profile web list 2>$null | Select-String -Quiet 'dsh-browser-use') {
        Write-Step 'Removing incompatible dsh plugin: dsh-browser-use'
        dsh plugin --profile web remove dsh-browser-use 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Warn2 '  dsh plugin remove dsh-browser-use failed' }
    }

    # `dsh-bot` is not DS Bot. It is a different package (dushaobindoudou/dsh-plugin:
    # a headless cron/webhook runner) that an earlier run of this script added to
    # every profile by mistake; drop it so only the correct `ds-bot` stays.
    foreach ($BotProfileDir in (Get-ChildItem (Join-Path $DshHome 'profiles') -Directory -ErrorAction SilentlyContinue)) {
        if (-not (Test-Path (Join-Path $BotProfileDir.FullName 'package.json'))) { continue }
        if ($BotProfileDir.Name -eq 'desktop') { continue }
        if (dsh plugin --profile $BotProfileDir.Name list 2>$null | Select-String -SimpleMatch -Quiet 'dsh-bot@') {
            Write-Step "Removing wrong bot plugin: dsh-bot (profile: $($BotProfileDir.Name))"
            dsh plugin --profile $BotProfileDir.Name remove dsh-bot 2>$null
            if ($LASTEXITCODE -ne 0) { Write-Warn2 "  dsh plugin remove dsh-bot failed on $($BotProfileDir.Name)" }
        }
    }

    # pnpm keeps the removed package's command shims under node_modules\.bin, so a
    # stale `dsh-bot` command would survive the uninstall; prune them too.
    foreach ($BotShimProfile in (Get-ChildItem (Join-Path $DshHome 'profiles') -Directory -ErrorAction SilentlyContinue)) {
        $BotShimBin = Join-Path $BotShimProfile.FullName 'node_modules\.bin'
        if (-not (Test-Path $BotShimBin)) { continue }
        Remove-Item (Join-Path $BotShimBin 'dsh-bot*') -Force -ErrorAction SilentlyContinue
    }

    # The dsh-tui launcher (`dst`) hard-fails when its version drifts from the
    # profile's @deepseek-harness-tui/dsh-tui bundle, so re-add the bundle at the
    # installed launcher version whenever the profile already exists (it is lazily
    # bootstrapped on first `dst`, so skip when absent).
    $DshTuiLauncher = (npm list -g --depth=0 '@deepseek-harness-tui/dsh-tui' 2>$null | ForEach-Object { if ($_ -match '@([^@]+)$') { $matches[1] } } | Select-Object -First 1)
    if ($DshTuiLauncher -and (Test-Path (Join-Path $DshHome 'profiles\dsh-tui\package.json'))) {
        Write-Step "Syncing dsh-tui bundle to launcher $DshTuiLauncher"
        dsh plugin --profile dsh-tui add "@deepseek-harness-tui/dsh-tui@$DshTuiLauncher" 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Warn2 "  dsh plugin sync @deepseek-harness-tui/dsh-tui@$DshTuiLauncher failed (may already be synced)" }
    }
} else {
    Write-Warn2 'dsh CLI not on PATH -- skipping dsh plugins (re-run after dsh is installed)'
}

# Desktop profile: Electron-owned and booted only by the app, but its plugin manager
# is the `dsh plugin` command inside the app bundle. Manage it with that command so
# it works whether or not an npm dsh CLI is installed, and give it the same
# skill/tool bundles as the CLI profiles above. Those bundles supply Desktop's
# modlens / agent-teams / engineering-skill-pack / mnemon / image-gen skills; the
# ~\.dsh\skills junctions from 7e2/7e3 already reach Desktop through dsh-base.
$DesktopProfile = Join-Path $DshHome 'profiles\desktop\package.json'
$DesktopRecord = Get-DshDesktopUninstallRecord
$DesktopInstall = if ($DesktopRecord) { $DesktopRecord.InstallLocation } else {
    $DesktopFallback = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness'
    if (Test-Path -LiteralPath (Join-Path $DesktopFallback 'DeepSeek Harness.exe')) { $DesktopFallback } else { $null }
}
$DesktopDsh = if ($DesktopInstall) { Join-Path $DesktopInstall 'resources\runtime\cli\bin\dsh.cmd' } else { $null }
if (Test-Path -LiteralPath $DesktopProfile) {
    if ($DesktopDsh -and (Test-Path -LiteralPath $DesktopDsh)) {
        # Electron owns this profile, but its pnpm settings live in the same file
        # the bundled command reads; record the expected peers before updating.
        Set-DshProfilePeerRules 'desktop'
        foreach ($DshBundle in $DshBundles) {
            Install-OrUpdate-DshPlugin 'desktop' $DshBundle $DesktopDsh
        }
    } else {
        Write-Warn2 '  DeepSeek Harness Desktop command not found -- skipping its plugins and skills'
    }
} elseif ($DesktopDsh -and (Test-Path -LiteralPath $DesktopDsh)) {
    Write-Host '  Launch DeepSeek Harness Desktop once to initialize its profile, then re-run this script for its plugins and skills'
}

# Grok Build — grok CLI plugin. `grok plugin install <name>` treats <name> as a
# marketplace plugin name (fails); use GitHub shorthand (user/repo) to install
# directly. install is non-idempotent (repeat errors "already installed"), so
# guard with `grok plugin list`: installed → update, absent → install.
if (Test-Cmd grok) {
    if (grok plugin list 2>$null | Select-String -Quiet 'yunxing') {
        Write-Step 'Updating yunxing Grok plugin'
        grok plugin update yunxing 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Warn2 '  grok plugin update failed' }
    } else {
        Write-Step 'Installing yunxing Grok plugin (raptoravis/yunxing)'
        grok plugin install raptoravis/yunxing --trust 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Warn2 '  grok plugin install failed' }
    }
} else {
    Write-Warn2 'grok CLI not on PATH -- skipping Grok plugin install (re-run after grok is installed)'
}

# Cursor & omp — no scriptable plugin install; link promoted skills into
# ~/.cursor/skills/ and omp's global skills dir ~/.omp/agent/skills (one level
# deep). $YunxingSrc is ensured above (shared with the Codex plugin version check).
if (Test-Path (Join-Path $YunxingSrc 'skills')) {
    Write-Step 'Linking yunxing skills into ~/.cursor/skills and ~/.omp/agent/skills'
    $SkillsDirs = @(
        (Join-Path $env:USERPROFILE '.cursor\skills'),
        (Join-Path $env:USERPROFILE '.omp\agent\skills')
    )
    foreach ($SkillsDir in $SkillsDirs) {
        New-Item -ItemType Directory -Force -Path $SkillsDir | Out-Null
        foreach ($bucket in @('engineering', 'productivity')) {
            $BucketDir = Join-Path $YunxingSrc "skills\$bucket"
            if (Test-Path $BucketDir) {
                foreach ($skillDir in (Get-ChildItem -Directory $BucketDir)) {
                    $link = Join-Path $SkillsDir $skillDir.Name
                    if (Test-Path $link) { cmd /c rmdir "$link" 2>$null }
                    New-Item -ItemType Junction -Path $link -Target $skillDir.FullName | Out-Null
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 7e) herdr agent skill — install the release-matched herdr SKILL.md into each
#     coding agent's global skills dir. `herdr --skill` prints the copy bundled
#     with the installed binary (no network, always matches the running version).
#     Written directly per-agent: grok isn't covered by the `npx skills` CLI.
# ---------------------------------------------------------------------------
if (Test-Cmd herdr) {
    Write-Step 'Installing herdr skill into coding agents (claude/codex/grok/opencode/cursor/omp)'
    $herdrSkillDirs = @(
        (Join-Path $env:USERPROFILE '.claude\skills\herdr'),
        (Join-Path $CodexHome 'skills\herdr'),
        (Join-Path $env:USERPROFILE '.grok\skills\herdr'),
        (Join-Path $env:USERPROFILE '.config\opencode\skills\herdr'),
        (Join-Path $env:USERPROFILE '.cursor\skills\herdr'),
        (Join-Path $env:USERPROFILE '.omp\agent\skills\herdr')
    )
    foreach ($dir in $herdrSkillDirs) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $skillFile = Join-Path $dir 'SKILL.md'
        # cmd /c redirect keeps herdr's raw UTF-8 bytes intact (PowerShell 5.1
        # would re-encode through the OEM codepage and mangle non-ASCII).
        cmd /c "herdr --skill > `"$skillFile`" 2>nul"
        if ($LASTEXITCODE -ne 0) { Write-Warn2 "  herdr --skill failed (writing $dir)" }
    }
} else {
    Write-Warn2 'herdr CLI not on PATH -- skipping herdr agent skill (re-run after herdr is installed)'
}

# ---------------------------------------------------------------------------
# 7e3) taste-skill (Leonxlnx/taste-skill) — anti-slop frontend design skills
#      (design taste, image-to-code, image generation, redesign, output
#      discipline). Multi-skill repo: every skills\<folder>\SKILL.md is linked
#      one level deep into each coding agent's global skills dir, named after
#      the frontmatter `name:` — the upstream install name, which differs from
#      the folder (taste-skill -> design-taste-frontend, soft-skill ->
#      high-end-visual-design) — falling back to the folder name.
#      dsh reads ~\.dsh\skills through its filesystem skill provider
#      (@deepseek-ai/dsh-base); the dst (dsh-tui) and Desktop profiles bundle
#      dsh-base too, so a single junction covers all three.
# ---------------------------------------------------------------------------
$TasteSkillSrc = Join-Path $env:USERPROFILE '.local\share\taste-skill'
if (Test-Cmd git) {
    if (Test-Path (Join-Path $TasteSkillSrc '.git')) {
        Write-Step 'Updating taste-skill checkout'
        git -C $TasteSkillSrc pull --ff-only --quiet 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Warn2 '  taste-skill pull failed' }
    } else {
        Write-Step 'Cloning taste-skill checkout'
        New-Item -ItemType Directory -Force -Path (Split-Path $TasteSkillSrc) | Out-Null
        git clone --depth=1 --quiet https://github.com/Leonxlnx/taste-skill.git $TasteSkillSrc 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Warn2 '  taste-skill clone failed' }
    }
    $tasteSkillAgentDirs = @(
        (Join-Path $env:USERPROFILE '.claude\skills'),
        (Join-Path $CodexHome 'skills'),
        (Join-Path $env:USERPROFILE '.grok\skills'),
        (Join-Path $DshHome 'skills'),
        (Join-Path $env:USERPROFILE '.config\opencode\skills'),
        (Join-Path $env:USERPROFILE '.cursor\skills'),
        (Join-Path $env:USERPROFILE '.omp\agent\skills')
    )
    $tasteSkillSrcDirs = @()
    $tasteSkillsRoot = Join-Path $TasteSkillSrc 'skills'
    if (Test-Path $tasteSkillsRoot) {
        $tasteSkillSrcDirs = @(Get-ChildItem -Path $tasteSkillsRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName 'SKILL.md') })
    }
    $tasteSkillNames = @()
    foreach ($SkillDir in $tasteSkillSrcDirs) {
        # Frontmatter `name:` is the upstream install name; fall back to the
        # folder name when it is missing or unusable as a path component.
        $name = ''
        foreach ($line in (Get-Content (Join-Path $SkillDir.FullName 'SKILL.md') -TotalCount 20)) {
            if ($line -match '^name:\s*(.+?)\s*$') { $name = $Matches[1].Trim('"', "'"); break }
        }
        if (-not $name -or $name -notmatch '^[A-Za-z0-9._-]+$') { $name = $SkillDir.Name }
        $tasteSkillNames += $name
        foreach ($dir in $tasteSkillAgentDirs) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            $link = Join-Path $dir $name
            # `rmdir` drops a junction (dangling ones included) without touching
            # its target — Remove-Item -Recurse would follow it and delete the
            # shared checkout.
            cmd /c rmdir "$link" 2>$null | Out-Null
            New-Item -ItemType Junction -Path $link -Target $SkillDir.FullName | Out-Null
        }
    }
    if ($tasteSkillNames.Count -eq 0) {
        Write-Warn2 '  taste-skill\skills\*\SKILL.md missing -- skipping agent links'
    } else {
        Write-Step "Linked $($tasteSkillNames.Count) taste-skill skills into coding agents (claude/codex/grok/dsh/dst/opencode/cursor/omp)"
        # Drop junctions left by an earlier run for a skill upstream no longer
        # ships: a removed/renamed skill would stay behind as a dangling
        # junction and the agent would then list a skill it cannot read.
        foreach ($dir in $tasteSkillAgentDirs) {
            $stale = @(Get-ChildItem -Path $dir -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.LinkType -eq 'Junction' -and (@($_.Target) -join ';') -like "$TasteSkillSrc\*" -and $tasteSkillNames -notcontains $_.Name })
            foreach ($entry in $stale) {
                cmd /c rmdir "$($entry.FullName)" 2>$null | Out-Null
                Write-Step "  removed stale taste-skill link: $($entry.Name)"
            }
        }
    }
} else {
    Write-Warn2 'git not on PATH -- skipping taste-skill (re-run after git is installed)'
}

# ---------------------------------------------------------------------------
# 7e4) BMad Method (bmad-code-org/BMAD-METHOD) — v7 ships the method as plain
#      agent skills (skills\<name>\SKILL.md). Clone it once and link every skill
#      directory into each agent's global skills dir, so claude/codex/grok/
#      dsh/dst/desktop/opencode/cursor/omp all see them. v7 is the preview line
#      on the default branch (main), not yet tagged. The per-project "bmad
#      setup" step still runs inside a project (it needs uv, installed earlier
#      by this script).
# ---------------------------------------------------------------------------
$BmadSkillsSrc = Join-Path $env:USERPROFILE '.local\share\bmad-method'
if (Test-Cmd git) {
    if (Test-Path (Join-Path $BmadSkillsSrc '.git')) {
        Write-Step 'Updating BMAD-METHOD checkout'
        git -C $BmadSkillsSrc pull --ff-only --quiet 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Warn2 '  BMAD-METHOD pull failed -- re-cloning'
            Remove-Item -Recurse -Force $BmadSkillsSrc -ErrorAction SilentlyContinue
        }
    }
    if (-not (Test-Path (Join-Path $BmadSkillsSrc '.git'))) {
        Write-Step 'Cloning BMAD-METHOD checkout'
        New-Item -ItemType Directory -Force -Path (Split-Path $BmadSkillsSrc) | Out-Null
        git clone --depth=1 --branch main --quiet https://github.com/bmad-code-org/BMAD-METHOD.git $BmadSkillsSrc 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Warn2 '  BMAD-METHOD clone failed' }
    }
    if (Test-Path (Join-Path $BmadSkillsSrc 'skills\bmad\SKILL.md')) {
        Write-Step 'Linking BMAD-METHOD skills into coding agents (claude/codex/grok/dsh/dst/desktop/opencode/cursor/omp)'
        $BmadSkillDests = @(
            (Join-Path $env:USERPROFILE '.claude\skills'),
            (Join-Path $CodexHome 'skills'),
            (Join-Path $env:USERPROFILE '.grok\skills'),
            (Join-Path $DshHome 'skills'),
            (Join-Path $env:USERPROFILE '.config\opencode\skills'),
            (Join-Path $env:USERPROFILE '.cursor\skills'),
            (Join-Path $env:USERPROFILE '.omp\agent\skills')
        )
        $BmadSkillDirs = @(Get-ChildItem -Path (Join-Path $BmadSkillsSrc 'skills') -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName 'SKILL.md') })
        $BmadSkillNames = @()
        foreach ($BmadSkillDir in $BmadSkillDirs) {
            $BmadSkillNames += $BmadSkillDir.Name
            foreach ($BmadDest in $BmadSkillDests) {
                New-Item -ItemType Directory -Force -Path $BmadDest | Out-Null
                $BmadLink = Join-Path $BmadDest $BmadSkillDir.Name
                # rmdir drops a junction (dangling ones included) without touching
                # its target; Remove-Item -Recurse would follow it.
                cmd /c rmdir "$BmadLink" 2>$null | Out-Null
                New-Item -ItemType Junction -Path $BmadLink -Target $BmadSkillDir.FullName | Out-Null
            }
        }
        if ($BmadSkillNames.Count -eq 0) {
            Write-Warn2 '  BMAD-METHOD\skills\*\SKILL.md missing -- skipping agent links'
        } else {
            Write-Step "Linked $($BmadSkillNames.Count) BMAD-METHOD skills into coding agents (claude/codex/grok/dsh/dst/desktop/opencode/cursor/omp)"
            # Drop junctions left for a skill upstream no longer ships.
            foreach ($BmadDest in $BmadSkillDests) {
                $BmadStale = @(Get-ChildItem -Path $BmadDest -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.LinkType -eq 'Junction' -and (@($_.Target) -join ';') -like "$BmadSkillsSrc\*" -and $BmadSkillNames -notcontains $_.Name })
                foreach ($BmadEntry in $BmadStale) {
                    cmd /c rmdir "$($BmadEntry.FullName)" 2>$null | Out-Null
                    Write-Step "  removed stale BMAD skill link: $($BmadEntry.Name)"
                }
            }
        }
    } else {
        Write-Warn2 '  BMAD-METHOD/skills/bmad/SKILL.md missing -- skipping agent links'
    }
} else {
    Write-Warn2 'git not on PATH -- skipping BMAD-METHOD skills (re-run after git is installed)'
}

# ---------------------------------------------------------------------------
# 7e5) bmad-loop - deterministic orchestrator for the BMAD implementation phase
#      (story -> dev -> verify -> review -> commit, unattended). Upstream ships
#      it from Git only (no PyPI, no npm), so it installs as a uv tool with the
#      TUI extra. Windows drives the native path, not WSL: the bundled psmux
#      backend launches the agent sessions, which needs psmux >= 3.4.0 and
#      pwsh >= 7.3 on PATH; bmad-loop run refuses to start below either.
#      Policy (verify commands, worktree isolation, review CLI) is per project
#      in .bmad-loop/policy.toml, written by "bmad-loop init" - nothing to set
#      up here. BMAD v7 support ships only on the default branch (the newest
#      vX.Y.Z tag still predates it), so this tracks main and refreshes it on
#      every run.
# ---------------------------------------------------------------------------
$BmadLoopRepo = 'https://github.com/bmad-code-org/bmad-loop.git'
$BmadLoopPython = '3.14'   # upstream verifies 3.11-3.14; a 3.15 default is untested

# psmux is the native-Windows multiplexer bmad-loop drives. Section 6 installs
# it and keeps it on the newest release (>= 3.4.0); verify it here so a broken
# upgrade surfaces next to the tool that needs it. Releases below 3.4.0 read as
# unavailable, and bmad-loop run then refuses to start.
$psmuxVersion = $null
if (Test-Cmd psmux) {
    $psmuxRaw = psmux -V 2>$null | Select-Object -First 1
    if ($psmuxRaw -match '(\d+\.\d+\.\d+)') { $psmuxVersion = [version]$Matches[1] }
}
if (-not $psmuxVersion) {
    Write-Warn2 "  psmux not found - bmad-loop's native Windows backend needs psmux >= $PsmuxFloor (re-run this script; winget install psmux as a fallback)"
} elseif ($psmuxVersion -lt $PsmuxFloor) {
    Write-Warn2 "  psmux $psmuxVersion is below bmad-loop's $PsmuxFloor floor"
}

# psmux runs every window under pwsh; bmad-loop wants 7.3 or newer.
if (Test-Cmd pwsh) {
    $pwshVer = $null
    try {
        $pwshVer = [version]((& (Get-Command pwsh).Source -NoProfile -Command '$PSVersionTable.PSVersion.ToString()').Trim())
    } catch { }
    if ($pwshVer -and $pwshVer -lt [version]'7.3') {
        Write-Warn2 "  pwsh $pwshVer is below bmad-loop's 7.3 floor (winget install Microsoft.PowerShell)"
    }
} else {
    Write-Warn2 "  pwsh not on PATH - bmad-loop's psmux backend needs PowerShell 7.3+"
}

if (-not (Test-Cmd uv)) {
    Write-Warn2 'uv not on PATH - skipping bmad-loop (re-run after uv is installed)'
} else {
    # BMAD v7 support ships only on the default branch (the newest vX.Y.Z tag
    # still predates it), so track main and refresh it on every run. main is not
    # versioned -- the tool reports the same version as the last release tag --
    # so there is no tag to version-compare against.
    $BmadLoopRef = 'main'
    $BmadLoopSpec = "bmad-loop[tui] @ git+$BmadLoopRepo@$BmadLoopRef"

    # uv tool shims land in `uv tool dir --bin`; refresh this session's PATH so a
    # tool installed by an earlier run is visible even when the shell predates it.
    $UvToolBin = @(uv tool dir --bin 2>$null) | Select-Object -First 1
    if ($UvToolBin -and (Test-Path $UvToolBin) -and ($UvToolBin -notin ($env:Path -split ';'))) {
        $env:Path = "$UvToolBin;$env:Path"
    }

    $bmadLoopInstalled = Test-Cmd bmad-loop

    if (-not $bmadLoopInstalled) {
        Write-Step "Installing bmad-loop[tui] ($BmadLoopRef, Python $BmadLoopPython)"
        uv tool install --python $BmadLoopPython $BmadLoopSpec
        if ($LASTEXITCODE -ne 0) { Write-Warn2 '  bmad-loop install failed' }
    } else {
        Write-Step "Refreshing bmad-loop from $BmadLoopRef"
        # --force moves an existing env (possibly a vX.Y.Z release) onto main.
        uv tool install --force --python $BmadLoopPython $BmadLoopSpec
        if ($LASTEXITCODE -ne 0) { Write-Warn2 '  bmad-loop refresh failed' }
    }

    if (Test-Cmd bmad-loop) {
        Write-Host '  per project: bmad-loop init --cli claude; bmad-loop validate; bmad-loop run'
        Write-Host '  native Windows backend: psmux (bmad-loop mux should report platform default for win32)'
    }
}

# ---------------------------------------------------------------------------
# 7f) Codex subagents (awesome-codex-subagents) — clone/update into the home
#     dir and copy selected agents into ~/.codex/agents/ (global, available in
#     every project). Ships all of 01-core-development plus a curated set across
#     02-language-specialists and 05-data-ai.
# ---------------------------------------------------------------------------
$CodexAgentsSrc = Join-Path $env:USERPROFILE 'awesome-codex-subagents'
$CodexAgentsDst = Join-Path $CodexHome 'agents'
if (Test-Cmd git) {
    if (Test-Path (Join-Path $CodexAgentsSrc '.git')) {
        Write-Step 'Updating awesome-codex-subagents checkout'
        git -C $CodexAgentsSrc pull --ff-only --quiet 2>$null
        if ($LASTEXITCODE -ne 0) {
            # pull failed — checkout is corrupt; drop it and re-clone below.
            Write-Warn2 '  awesome-codex-subagents pull failed -- re-cloning'
            Remove-Item -Recurse -Force $CodexAgentsSrc
        }
    }
    if (-not (Test-Path (Join-Path $CodexAgentsSrc '.git'))) {
        Write-Step "Cloning awesome-codex-subagents into $CodexAgentsSrc"
        git clone --depth=1 --quiet https://github.com/VoltAgent/awesome-codex-subagents.git $CodexAgentsSrc 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Warn2 '  awesome-codex-subagents clone failed' }
    }
    if (Test-Path (Join-Path $CodexAgentsSrc 'categories')) {
        Write-Step "Syncing Codex subagents into $CodexAgentsDst"
        New-Item -ItemType Directory -Force -Path $CodexAgentsDst | Out-Null
        Copy-Item (Join-Path $CodexAgentsSrc 'categories\01-core-development\*.toml') -Destination $CodexAgentsDst -Force -ErrorAction SilentlyContinue
        $extraAgents = @(
            '02-language-specialists\node-specialist',
            '02-language-specialists\javascript-pro',
            '02-language-specialists\fastapi-developer',
            '02-language-specialists\nextjs-developer',
            '02-language-specialists\python-pro',
            '02-language-specialists\typescript-pro',
            '02-language-specialists\vue-expert',
            '02-language-specialists\react-specialist',
            '02-language-specialists\sql-pro',
            '05-data-ai\database-optimizer',
            '05-data-ai\postgres-pro',
            '05-data-ai\prompt-engineer',
            '05-data-ai\llm-architect'
        )
        foreach ($rel in $extraAgents) {
            $src = Join-Path $CodexAgentsSrc "categories\$rel.toml"
            if (Test-Path $src) {
                Copy-Item $src -Destination $CodexAgentsDst -Force
            } else {
                Write-Warn2 "  missing agent: $rel.toml"
            }
        }
    } else {
        Write-Warn2 '  awesome-codex-subagents/categories missing -- skipping agent copy'
    }
} else {
    Write-Warn2 'git not on PATH -- skipping Codex subagents install (re-run after git is installed)'
}

# ---------------------------------------------------------------------------
# 8) Environment variables (XDG_CONFIG_HOME, YAZI_CONFIG_HOME, PATH)
# ---------------------------------------------------------------------------
Write-Step 'Setting user environment variables'
function Set-UserEnvVarIfChanged($name, $value) {
    $current = [Environment]::GetEnvironmentVariable($name, 'User')
    if ($current -eq $value) {
        Write-Host "  $name already set"
    } else {
        [Environment]::SetEnvironmentVariable($name, $value, 'User')
        Write-Host "  set $name = $value"
    }
}
Set-UserEnvVarIfChanged 'XDG_CONFIG_HOME'  "$env:USERPROFILE\.config"
Set-UserEnvVarIfChanged 'YAZI_CONFIG_HOME' "$env:USERPROFILE\.config\yazi"

# Proxy — applied at the user scope so non-pwsh processes (vscode, etc.)
# also route through it. The pwsh profile sets the
# same value at session scope via proxy_on; setting it at user scope makes
# it visible before the profile runs.
if ($ProxyUrl) {
    Set-UserEnvVarIfChanged 'HTTPS_PROXY' $ProxyUrl
    Set-UserEnvVarIfChanged 'HTTP_PROXY'  $ProxyUrl
    Set-UserEnvVarIfChanged 'ALL_PROXY'   $ProxyUrl
    if ((git config --global --get http.proxy 2>$null) -ne $ProxyUrl) {
        git config --global http.proxy  $ProxyUrl
        git config --global https.proxy $ProxyUrl
        Write-Host "  set git http.proxy/https.proxy = $ProxyUrl"
    } else {
        Write-Host '  git http.proxy already set'
    }
}

# Git global config (identity + sane defaults). Idempotent: only writes on change.
function Set-GitConfigIfChanged {
    param([string]$Key, [string]$Value)
    if ((git config --global --get $Key 2>$null) -ne $Value) {
        git config --global $Key $Value
        Write-Host "  set git $Key = $Value"
    }
}
# Identity: only set from env vars; never overwrite existing values.
if ($env:GIT_USER_NAME -and -not (git config --global --get user.name 2>$null)) {
    Set-GitConfigIfChanged 'user.name'  $env:GIT_USER_NAME
}
if ($env:GIT_USER_EMAIL -and -not (git config --global --get user.email 2>$null)) {
    Set-GitConfigIfChanged 'user.email' $env:GIT_USER_EMAIL
}
Set-GitConfigIfChanged 'http.version'     'HTTP/1.1'
Set-GitConfigIfChanged 'http.postBuffer'  '524288000'
Set-GitConfigIfChanged 'core.longpaths'   'true'
Set-GitConfigIfChanged 'core.compression' '0'
Set-GitConfigIfChanged 'core.quotepath'   'false'

# SSH: route github.com over 443 (port 22 is blocked on some networks).
$SshDir    = Join-Path $env:USERPROFILE '.ssh'
$SshConfig = Join-Path $SshDir 'config'
if (-not (Test-Path $SshDir))    { New-Item -ItemType Directory -Path $SshDir    -Force | Out-Null }
if (-not (Test-Path $SshConfig)) { New-Item -ItemType File      -Path $SshConfig -Force | Out-Null }
$sshContent = Get-Content -Raw -LiteralPath $SshConfig -ErrorAction SilentlyContinue
if (-not ($sshContent -match '(?m)^\s*Hostname\s+ssh\.github\.com\b')) {
    $block = "Host github.com`n  Hostname ssh.github.com`n  Port 443`n  User git`n"
    if ($sshContent -and -not $sshContent.EndsWith("`n")) { Add-Content -LiteralPath $SshConfig -Value '' }
    Add-Content -LiteralPath $SshConfig -Value $block -NoNewline
    Write-Host "  appended github.com:443 block to $SshConfig"
}

# Add ~/.cargo/bin to the user PATH so cargo-installed tools (dotter, eza, btm…) are found
# in new shells without requiring a rustup-managed PATH update.
$CargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
if (Test-Path $CargoBin) {
    $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    $entries  = if ($userPath) { $userPath -split ';' } else { @() }
    $already  = $entries | Where-Object { $_ -and ($_.TrimEnd('\') -ieq $CargoBin.TrimEnd('\')) }
    if ($already) {
        Write-Host '  ~/.cargo/bin already on user PATH'
    } else {
        $newPath = if ($userPath) { "$userPath;$CargoBin" } else { $CargoBin }
        [Environment]::SetEnvironmentVariable('PATH', $newPath, 'User')
        Write-Host "  added to user PATH: $CargoBin"
    }
} else {
    Write-Warn2 '~/.cargo/bin not found — Rust may not be installed yet; re-run after rustup'
}

# Add ~/AppData/Roaming/npm to the user PATH so global npm CLIs (hostc, codex, gemini, …)
# are findable. The official Node MSI used to set this; scoop's nodejs-lts does not.
$NpmGlobal = Join-Path $env:APPDATA 'npm'
$userPath  = [Environment]::GetEnvironmentVariable('PATH', 'User')
$entries   = if ($userPath) { $userPath -split ';' } else { @() }
$already   = $entries | Where-Object { $_ -and ($_.TrimEnd('\') -ieq $NpmGlobal.TrimEnd('\')) }
if ($already) {
    Write-Host '  ~/AppData/Roaming/npm already on user PATH'
} else {
    $newPath = if ($userPath) { "$userPath;$NpmGlobal" } else { $NpmGlobal }
    [Environment]::SetEnvironmentVariable('PATH', $newPath, 'User')
    Write-Host "  added to user PATH: $NpmGlobal"
}

# Add dotfiles windows/bin to the user PATH (idempotent, case-insensitive match).
$BinDir = Join-Path $DotfilesDir 'windows\bin'
if (Test-Path $BinDir) {
    $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    $entries  = if ($userPath) { $userPath -split ';' } else { @() }
    $already  = $entries | Where-Object { $_ -and ($_.TrimEnd('\') -ieq $BinDir.TrimEnd('\')) }
    if ($already) {
        Write-Host "  windows\bin already on user PATH"
    } else {
        $newPath = if ($userPath) { "$userPath;$BinDir" } else { $BinDir }
        [Environment]::SetEnvironmentVariable('PATH', $newPath, 'User')
        Write-Host "  added to user PATH: $BinDir"
    }
} else {
    Write-Warn2 "windows\bin not found at $BinDir — skipping PATH update"
}

# ---------------------------------------------------------------------------
# 8b) Enable Developer Mode (lets non-admin users create symlinks)
#     Required so dotter symlinks configs instead of copying. Setting the
#     HKLM key requires admin; if not elevated, warn and continue (dotter
#     will fall back to file copies).
# ---------------------------------------------------------------------------
$DevModeKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
$DevModeVal = 'AllowDevelopmentWithoutDevLicense'
$devCurrent = Get-ItemProperty -Path $DevModeKey -Name $DevModeVal -ErrorAction SilentlyContinue
if ($devCurrent -and $devCurrent.$DevModeVal -eq 1) {
    Write-Step 'Developer Mode already enabled'
} else {
    if (Test-Admin) {
        Write-Step 'Enabling Developer Mode (for symlink permission)'
        if (-not (Test-Path $DevModeKey)) {
            New-Item -Path $DevModeKey -Force | Out-Null
        }
        New-ItemProperty -Path $DevModeKey -Name $DevModeVal -PropertyType DWord -Value 1 -Force | Out-Null
        Write-Host '  Developer Mode enabled — dotter can now create symlinks'
    } else {
        Write-Warn2 'Developer Mode is OFF and shell is not elevated.'
        Write-Warn2 '  dotter will fall back to copying files instead of symlinking.'
        Write-Warn2 '  To enable: re-run this script in an admin PowerShell, or toggle'
        Write-Warn2 '  Settings -> Privacy & security -> For developers -> Developer Mode'
    }
}

# ---------------------------------------------------------------------------
# 9) Ensure .dotter/local.toml exists (gitignored, machine-local)
#    Tells dotter which package set to apply without needing a hostname file.
# ---------------------------------------------------------------------------
$LocalToml = Join-Path $DotfilesDir '.dotter\local.toml'
$herdrShellLine = 'herdr_shell = "pwsh.exe"'
if (Test-Path $LocalToml) {
    $tomlLines = @(Get-Content -Path $LocalToml)
    if ($tomlLines -match '^\s*herdr_shell\s*=') {
        Write-Step '.dotter/local.toml already has herdr_shell'
    } else {
        # Insert herdr_shell under an existing [variables] table if present,
        # otherwise append a new [variables] table.
        $varIdx = ($tomlLines | Select-String '^\s*\[variables\]\s*$' | Select-Object -First 1).LineNumber
        if ($varIdx) {
            $out = @()
            $i = 0
            foreach ($line in $tomlLines) {
                $out += $line
                $i++
                if ($i -eq $varIdx) { $out += $herdrShellLine }
            }
            Set-Content -Path $LocalToml -Value $out -Encoding UTF8
        } else {
            Set-Content -Path $LocalToml -Value ($tomlLines + @('', '[variables]', $herdrShellLine)) -Encoding UTF8
        }
        Write-Step 'Added herdr_shell = "pwsh.exe" to .dotter/local.toml'
    }
} else {
    Write-Step 'Creating .dotter/local.toml (packages: common + windows)'
    Set-Content -Path $LocalToml -Value @(
        'packages = [ "common", "windows" ]'
        ''
        '[variables]'
        $herdrShellLine
    ) -Encoding UTF8
}

# ---------------------------------------------------------------------------
# 10) Symlinks via dotter
# ---------------------------------------------------------------------------
if (Test-Cmd dotter) {
    Write-Step 'Symlinking dotfiles via dotter'
    Push-Location $DotfilesDir
    try {
        # Dotter labels "already exists. Skipping." and the trailing
        # "Some files were skipped." summary as [ERROR], but those are
        # not real failures -- downgrade them to [WARN ] (yellow).
        $softErrorPattern = 'already exists\. Skipping\.|Some files were skipped\.'
        dotter -v --force 2>&1 | ForEach-Object {
            $line = $_.ToString()
            if ($line -match '^\[ERROR\]') {
                if ($line -match $softErrorPattern) {
                    Write-Host ($line -replace '^\[ERROR\]', '[WARN ]') -ForegroundColor Yellow
                } else {
                    Write-Host $line -ForegroundColor Red
                }
            } else {
                Write-Host $line
            }
        }
    } catch { Write-Warn2 "dotter exited with errors: $_" }
    Pop-Location
} else {
    Write-Warn2 'dotter not on PATH — open a new shell so cargo bin is loaded, then re-run.'
}

# ---------------------------------------------------------------------------
# 10b) ~/.wslconfig — real copy, never a symlink.
#      WSL refuses to read a config that resolves through a reparse point on
#      another volume:
#        wsl: 未能打开配置文件 C:\Users\<you>\.wslconfig，无法遍历该路径，因为它们包含不受信任的装入点
#      and silently keeps the default `nat` networking, so
#      `networkingMode=mirrored` never applied (127.0.0.1 then does not reach the
#      Windows host — Clash proxies, port workarounds etc. all break). dotter no
#      longer maps this file (see .dotter/global.toml); deploy a real copy here,
#      AFTER dotter, so a stale dotter cache can't leave it deleted or linked.
# ---------------------------------------------------------------------------
$WslConfigSrc = Join-Path $DotfilesDir 'windows\wsl\.wslconfig'
$WslConfigDst = Join-Path $env:USERPROFILE '.wslconfig'
function Get-FileSha256 ([string]$Path) {
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        return ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path))) -replace '-', '')
    } catch { return '' }
}
if (Test-Path $WslConfigSrc) {
    $WslConfigExisting = Get-Item $WslConfigDst -Force -ErrorAction SilentlyContinue
    $WslConfigLinked = [bool]($WslConfigExisting -and $WslConfigExisting.LinkType)
    $WslConfigStale = -not $WslConfigExisting -or $WslConfigLinked
    if (-not $WslConfigStale) {
        $WslConfigStale = (Get-FileSha256 $WslConfigSrc) -ne (Get-FileSha256 $WslConfigDst)
    }
    if ($WslConfigStale) {
        if ($WslConfigLinked) {
            Write-Step 'Replacing symlinked ~/.wslconfig with a real copy (WSL cannot read it across volumes)'
        } else {
            Write-Step 'Deploying ~/.wslconfig (real copy)'
        }
        Remove-Item $WslConfigDst -Force -ErrorAction SilentlyContinue
        Copy-Item $WslConfigSrc $WslConfigDst -Force
        Write-Warn2 '  .wslconfig updated — run `wsl --shutdown` so WSL applies the new networking settings'
    } else {
        Write-Step '~/.wslconfig already up to date (real file)'
    }
} else {
    Write-Warn2 'windows\wsl\.wslconfig not found — skipping ~/.wslconfig deploy'
}

# ---------------------------------------------------------------------------
# 11) Windows Terminal settings directory (Scoop portable mode).
#     Scoop-installed windows-terminal >= 1.17 uses portable mode; settings
#     live under the app dir rather than the packaged LocalState folder.
# ---------------------------------------------------------------------------
$WinTermDir = Join-Path $env:USERPROFILE 'scoop\apps\windows-terminal\current\settings'
if (-not (Test-Path $WinTermDir)) {
    New-Item -ItemType Directory -Path $WinTermDir -Force | Out-Null
    Write-Host "  created $WinTermDir"
}

# ---------------------------------------------------------------------------
# 12) WinUtil (ChrisTitusTech) launcher
#     WinUtil is a run-on-demand, admin-required GUI tool with no scoop/winget
#     package -- upstream only ships the `irm https://christitus.com/win | iex`
#     launch command. The `winutil` launcher lives in windows\bin (already on
#     the user PATH from step 8); just confirm it's present.
# ---------------------------------------------------------------------------
$WinUtilLauncher = Join-Path $DotfilesDir 'windows\bin\winutil.bat'
if (Test-Path $WinUtilLauncher) {
    Write-Step 'WinUtil launcher available on PATH'
    Write-Host '  run `winutil` (elevation prompt appears) to launch ChrisTitusTech WinUtil'
} else {
    Write-Warn2 "WinUtil launcher missing at $WinUtilLauncher"
}

Write-Step 'Done. Open a new terminal to pick up the environment.'
Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Next: install WSL with `wsl --install`, open Ubuntu, then run install-linux.sh inside WSL.' -ForegroundColor DarkGray
