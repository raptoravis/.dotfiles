# install-windows.ps1 — Windows host dotfiles & dev environment bootstrap
#
# Usage (run from a regular PowerShell prompt — admin not required for Scoop):
#   powershell -ExecutionPolicy Bypass -File .\install-windows.ps1
#   .\install-windows.ps1 -DotfilesDir "$env:USERPROFILE\.dotfiles"
#
# Idempotent: safe to re-run. Mirrors `cargo make init` for Windows host.
# This script targets the Windows host (Scoop, native GUI apps). For the
# WSL2 / unix backend layer, run install-linux.sh inside WSL2.

[CmdletBinding()]
param(
    [string]$DotfilesDir = $PSScriptRoot,
    # HTTP proxy applied as user-level HTTPS_PROXY/HTTP_PROXY/ALL_PROXY and to
    # `git config --global`. Mirrors $env:PROXY_URL in the pwsh profile so
    # tools launched outside pwsh (vscode, etc.) reach
    # the network through the same proxy. Pass '' to skip.
    [string]$ProxyUrl = 'http://127.0.0.1:7890',
    # Uninstall all AI agent CLIs (Claude Code, Codex, OpenCode,
    # DeepSeek Harness, Pi) and remove their config directories.
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
function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }

if ($UninstallAgents) {
    Write-Step 'Uninstalling AI agent CLIs and cleaning config directories'

    # 1) npm global uninstall
    if (Test-Cmd npm) {
        $AgentPackages = @(
            '@anthropic-ai/claude-code',
            '@openai/codex',
            'opencode-ai',
            '@deepseek-ai/dsh',
            '@earendil-works/pi-coding-agent'
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

    # 2) Remove agent config directories

    $AgentDirs = @(
        (Join-Path $env:USERPROFILE '.claude'),
        $CodexHome,
        (Join-Path $env:USERPROFILE '.config\opencode'),
        $DshHome,
        (Join-Path $env:USERPROFILE '.pi'),
        (Join-Path $env:USERPROFILE '.agents'),
        (Join-Path $env:USERPROFILE '.cache\dotfiles\agent-plugins'),
        (Join-Path $env:USERPROFILE '.cache\opencode'),
        (Join-Path $env:USERPROFILE '.cache\claude'),
        (Join-Path $env:USERPROFILE '.cache\codex'),
        (Join-Path $env:USERPROFILE '.cache\dsh')
    )
    foreach ($d in $AgentDirs) {
        if (Test-Path $d) {
            Write-Step "  rm -r -fo $d"
            Remove-Item -Recurse -Force -LiteralPath $d -ErrorAction SilentlyContinue
        } else {
            Write-Step "  skip (not found): $d"
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
$Deps      = @('autohotkey', 'cmake', 'fastfetch', 'firacode')

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

# Stop the scoop-managed service for $pkg so its shim can be replaced. Returns
# $true when it's safe to update (stopped, already stopped, or not registered);
# $false when the stop failed (e.g. no admin token) and the update must be skipped.
function Stop-ScoopService($pkg) {
    if (-not (Test-ScoopServiceRunning $pkg)) { return $true }
    sc.exe stop $pkg *>$null
    return ($LASTEXITCODE -eq 0)
}

# Restart the service we stopped, unless it's not registered or is disabled.
function Start-ScoopService($pkg) {
    $svc = Get-Service -Name $pkg -ErrorAction SilentlyContinue
    if ($null -eq $svc -or $svc.StartType -eq 'Disabled') { return }
    sc.exe start $pkg *>$null
}

# Non-admin path: elevate via UAC to run `stop -> update -> start` for a service
# package. Output is captured to a temp log and replayed. If the user declines
# UAC, fall back to a skip + pointer.
function Invoke-ScoopServiceUpdateElevated($pkg) {
    $log = Join-Path $env:TEMP "$pkg-scoop-update.log"
    Remove-Item $log -ErrorAction SilentlyContinue
    $inner = "& { sc.exe stop $pkg; scoop update $pkg; sc.exe start $pkg; sc.exe query $pkg } *>> '$log'"
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
                        scoop update $p
                        if ($LASTEXITCODE -ne 0) { Write-Warn2 "  update failed: $p" }
                        Start-ScoopService $p
                    } else {
                        Write-Warn2 "  $p update skipped -- could not stop service"
                    }
                } else {
                    Invoke-ScoopServiceUpdateElevated $p
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
    $WingetApps = @('Microsoft.PowerToys', 'Microsoft.Coreutils')
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

# ---------------------------------------------------------------------------
# 4d) Visual Studio Build Tools — C++ compiler, MSBuild, CMake, headers.
#     Needed by: Neovim Telescope FZF Native (requires gcc/cl), Windows
#     Cargo builds (cc crate), Python native extensions, Windows SDK.
#     Installed via the VS Bootstrapper; only downloads what's needed.
#     Workload: VCTools (Desktop development with C++).
#     Idempotent: `vs_where` detects existing installs.
# ---------------------------------------------------------------------------
$VSBootstrapUrl = 'https://aka.ms/vs/17/release/vs_BuildTools.exe'
$VSBootstrapExe = Join-Path $env:TEMP 'vs_BuildTools.exe'
$VsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"

# Check if Build Tools are already installed by looking for vswhere or any
# instance with the VCTools workload.
$VsFound = $false
if (Test-Path $VsWhere) {
    $vsInstance = & $VsWhere -latest -products '*' -requires 'Microsoft.VisualStudio.Workload.VCTools' -format json 2>$null | ConvertFrom-Json
    if ($vsInstance -and $vsInstance.Length -gt 0) {
        Write-Step "Visual Studio Build Tools already installed: $($vsInstance[0].displayName)"
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
    'psmux'        = 'psmux'
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
#     Code's machine-local overlay), kept separate from the cc-switch-managed
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
# 7b) Grok Build
# ---------------------------------------------------------------------------
if (-not (Test-Cmd grok)) {
    Write-Step 'Installing Grok Build'
    irm 'https://x.ai/cli/install.ps1' | iex
    if (-not (Test-Cmd grok)) { Write-Warn2 '  Grok Build install failed or grok is not yet on PATH' }
} else {
    Write-Host '  Grok Build already installed'
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
    # AI coding CLIs (Claude Code / Codex / OpenCode / DeepSeek Harness / Pi)
    if (-not (Test-Cmd claude)) {
        Write-Step 'Installing Claude Code CLI (@anthropic-ai/claude-code)'
        npm install -g '@anthropic-ai/claude-code'
        if ($LASTEXITCODE -ne 0) { Write-Warn2 '  claude-code install failed' }
    }
    if (-not (Test-Cmd codex)) {
        Write-Step 'Installing Codex CLI (@openai/codex)'
        npm install -g '@openai/codex'
        if ($LASTEXITCODE -ne 0) { Write-Warn2 '  codex install failed' }
    }
    if (-not (Test-Cmd opencode)) {
        Write-Step 'Installing OpenCode CLI (opencode-ai)'
        npm install -g 'opencode-ai'
        if ($LASTEXITCODE -ne 0) { Write-Warn2 '  opencode install failed' }
    }
    # DeepSeek Harness — official DeepSeek native agent framework. bin: `dsh`,
    # profile/state under $DshHome\profiles. Node ^22.19 || >=24.
    if (-not (Test-Cmd dsh)) {
        Write-Step 'Installing DeepSeek Harness CLI (@deepseek-ai/dsh)'
        npm install -g '@deepseek-ai/dsh'
        if ($LASTEXITCODE -ne 0) { Write-Warn2 '  dsh (DeepSeek Harness) install failed (requires Node.js >= 22.19)' }
    }
    # Pi — earendil-works coding agent CLI (unified LLM API, agent loop, TUI). bin: `pi`.
    # Skills are loaded from ~/.pi/agent/skills/ and ~/.agents/skills/.
    if (-not (Test-Cmd pi)) {
        Write-Step 'Installing Pi coding agent CLI (@earendil-works/pi-coding-agent)'
        npm install -g '@earendil-works/pi-coding-agent'
        if ($LASTEXITCODE -ne 0) { Write-Warn2 '  pi install failed' }
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
    # opencode: merge an `mcp.github` (remote) entry into its JSON
    # config idempotently.
    if (Test-Cmd node) {
        function Register-JsonMcp([string]$File, [string]$AddJson) {
            $env:MCP_FILE = $File
            $env:MCP_ADD = $AddJson
            node -e 'const fs=require("fs"), path=require("path"); const f=process.env.MCP_FILE, add=JSON.parse(process.env.MCP_ADD); let c={}; try{ c=JSON.parse(fs.readFileSync(f,"utf8")); }catch(e){} c.mcp=(c.mcp&&typeof c.mcp==="object")?c.mcp:{}; let changed=false; for(const [k,v] of Object.entries(add)){ if(!c.mcp[k]){ c.mcp[k]=v; changed=true; } } if(changed){ fs.mkdirSync(path.dirname(f),{recursive:true}); fs.writeFileSync(f, JSON.stringify(c,null,2)+"\n"); }'
            if ($LASTEXITCODE -ne 0) { Write-Warn2 "  failed to write MCP config to $File" }
            Remove-Item Env:MCP_FILE, Env:MCP_ADD -ErrorAction SilentlyContinue
        }
        if ($GhMcpPat) {
            $GhRemoteJson = '{"github":{"type":"remote","url":"' + $GhMcpUrl + '","enabled":true,"headers":{"Authorization":"Bearer ' + $GhMcpPat + '"}}}'
        } else {
            $GhRemoteJson = '{"github":{"type":"remote","url":"' + $GhMcpUrl + '","enabled":true}}'
        }
        $CdtLocalJson = '{"chrome-devtools":{"type":"local","command":["npx","-y","chrome-devtools-mcp@latest"],"enabled":true}}'
        $FetchLocalJson = '{"fetch":{"type":"local","command":["npx","-y","mcp-fetch-server"],"enabled":true}}'
        $Ctx7LocalJson = '{"context7":{"type":"local","command":["npx","-y","@upstash/context7-mcp"],"enabled":true}}'
        if (Test-Cmd opencode) {
            Write-Step 'Registering github + chrome-devtools + fetch + context7 MCP for opencode (~/.config/opencode/opencode.json)'
            Register-JsonMcp "$HOME\.config\opencode\opencode.json" $GhRemoteJson
            Register-JsonMcp "$HOME\.config\opencode\opencode.json" $CdtLocalJson
            Register-JsonMcp "$HOME\.config\opencode\opencode.json" $FetchLocalJson
            Register-JsonMcp "$HOME\.config\opencode\opencode.json" $Ctx7LocalJson
        }
    }
} else {
    Write-Warn2 'npm not on PATH -- skipping npm-based CLI installs (open a new shell after scoop installs nodejs-lts, then re-run)'
}

# ---------------------------------------------------------------------------
# 7c) pnpm via corepack (ships with Node >= 16.10)
# ---------------------------------------------------------------------------
if (Test-Cmd corepack) {
    Write-Step 'Enabling pnpm via corepack'
    corepack enable
    if ($LASTEXITCODE -ne 0) { Write-Warn2 '  corepack enable failed' }
    corepack prepare pnpm@latest --activate
    if ($LASTEXITCODE -ne 0) { Write-Warn2 '  corepack prepare pnpm failed' }
} else {
    Write-Warn2 'corepack not on PATH -- skipping pnpm activation (open a new shell after scoop installs nodejs-lts, then re-run)'
}

# ---------------------------------------------------------------------------
# 7d) Yunxing plugin (raptoravis/yunxing)
#     Claude Code — marketplace name "yunxing" (derived from
#     .claude-plugin/marketplace.json), plugin selector "yunxing@yunxing".
#     Also redundantly declared in common/claude/settings.json (enabledPlugins)
#     for fresh dotter-only setups.
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

if (Test-Cmd codex) {
    Write-Step 'Installing yunxing Codex plugin (marketplace: yunxing)'
    codex plugin marketplace add raptoravis/yunxing 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Warn2 '  codex marketplace add failed' }
    codex plugin add yunxing@yunxing 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Warn2 '  codex plugin add failed' }
} else {
    Write-Warn2 'codex CLI not on PATH -- skipping Codex plugin install (re-run after codex is installed)'
}

# OpenCode — native plugin module (one-step; no marketplace concept).
if (Test-Cmd opencode) {
    Write-Step 'Installing yunxing OpenCode plugin'
    opencode plugin --force -g 'yunxing@git+https://github.com/raptoravis/yunxing.git' 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Warn2 '  opencode plugin install failed' }
} else {
    Write-Warn2 'opencode CLI not on PATH -- skipping OpenCode plugin install (re-run after opencode is installed)'
}

# dsh — DeepSeek Harness bundle (package.json dsh.bundle → cordis.patch.yml).
if (Test-Cmd dsh) {
    Write-Step 'Installing yunxing dsh bundle'
    dsh plugin --profile web add github:raptoravis/yunxing 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Warn2 '  dsh plugin add failed (may already be installed)' }
} else {
    Write-Warn2 'dsh CLI not on PATH -- skipping dsh yunxing bundle (re-run after dsh is installed)'
}

# Grok Build — grok CLI plugin marketplace (reads yunxing's .grok-plugin/marketplace.json).
if (Test-Cmd grok) {
    Write-Step 'Installing yunxing Grok plugin (marketplace: yunxing)'
    grok plugin marketplace add raptoravis/yunxing 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Warn2 '  grok marketplace add failed (may already be registered)' }
    grok plugin install yunxing --trust 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Warn2 '  grok plugin install failed' }
} else {
    Write-Warn2 'grok CLI not on PATH -- skipping Grok plugin install (re-run after grok is installed)'
}

# Cursor — no scriptable plugin install; link promoted skills into ~/.cursor/skills/ (junction, no admin needed).
$YunxingSrc = Join-Path $env:USERPROFILE '.local\share\yunxing'
if (Test-Cmd git) {
    if (Test-Path (Join-Path $YunxingSrc '.git')) {
        Write-Step 'Updating yunxing checkout for Cursor skills'
        git -C $YunxingSrc pull --ff-only --quiet 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Warn2 '  yunxing pull failed' }
    } else {
        Write-Step 'Cloning yunxing for Cursor skills'
        New-Item -ItemType Directory -Force -Path (Split-Path $YunxingSrc) | Out-Null
        git clone --depth=1 --quiet https://github.com/raptoravis/yunxing.git $YunxingSrc 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Warn2 '  yunxing clone failed' }
    }
    if (Test-Path (Join-Path $YunxingSrc 'skills')) {
        Write-Step 'Linking yunxing skills into ~/.cursor/skills'
        $SkillsDir = Join-Path $env:USERPROFILE '.cursor\skills'
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
} else {
    Write-Warn2 'git not on PATH -- skipping Cursor yunxing skills'
}

# ---------------------------------------------------------------------------
# 7e) herdr agent skill — install the release-matched herdr SKILL.md into each
#     coding agent's global skills dir. `herdr --skill` prints the copy bundled
#     with the installed binary (no network, always matches the running version).
#     Written directly per-agent: grok isn't covered by the `npx skills` CLI.
# ---------------------------------------------------------------------------
if (Test-Cmd herdr) {
    Write-Step 'Installing herdr skill into coding agents (claude/codex/grok/opencode/cursor)'
    $herdrSkillDirs = @(
        (Join-Path $env:USERPROFILE '.claude\skills\herdr'),
        (Join-Path $CodexHome 'skills\herdr'),
        (Join-Path $env:USERPROFILE '.grok\skills\herdr'),
        (Join-Path $env:USERPROFILE '.config\opencode\skills\herdr'),
        (Join-Path $env:USERPROFILE '.cursor\skills\herdr')
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
if (Test-Path $LocalToml) {
    Write-Step '.dotter/local.toml already exists'
} else {
    Write-Step 'Creating .dotter/local.toml (packages: common + windows)'
    Set-Content -Path $LocalToml -Value 'packages = [ "common", "windows" ]' -Encoding UTF8
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
        dotter -v 2>&1 | ForEach-Object {
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
# 10b) MANUAL: sync Claude settings into cc-switch
#     ~/.claude/settings.json is NOT symlinked by dotter — cc-switch owns it and
#     injects the env block (ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN) on every
#     provider switch. The repo's common/claude/settings.json is the shared
#     *base* (permissions / hooks / enabledPlugins / statusLine). You must copy
#     that base into cc-switch's common config ("通用配置") by hand so cc-switch
#     composes base + per-provider env into ~/.claude/settings.json. Skipping
#     this means the shared settings won't apply after a provider switch.
# ---------------------------------------------------------------------------
Write-Warn2 'MANUAL STEP: sync common/claude/settings.json into cc-switch "通用配置" (cc-switch owns ~/.claude/settings.json; dotter no longer symlinks it).'

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
Write-Host 'Next: install WSL2 with `wsl --install`, open Ubuntu, then run install-linux.sh inside WSL.' -ForegroundColor DarkGray
