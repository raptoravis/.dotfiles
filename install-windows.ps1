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
    # tools launched outside pwsh (wezterm plugin clones, vscode, etc.) reach
    # the network through the same proxy. Pass '' to skip.
    [string]$ProxyUrl = 'http://127.0.0.1:7890'
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

# ---------------------------------------------------------------------------
# 1) Scoop (user-scope package manager — no admin required)
# ---------------------------------------------------------------------------
if (-not (Test-Cmd scoop)) {
    Write-Step 'Installing Scoop'
    # Scoop's installer requires RemoteSigned for the current user.
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
    Invoke-RestMethod -Uri 'https://get.scoop.sh' | Invoke-Expression
} else {
    Write-Step "Scoop already installed: $(scoop --version | Select-Object -First 1)"
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
scoop bucket add extras     2>$null | Out-Null
scoop bucket add nerd-fonts 2>$null | Out-Null
scoop bucket add versions   2>$null | Out-Null

# ---------------------------------------------------------------------------
# 3) Core tools, languages, dependencies (matches Makefile.toml `windows-tools`)
# ---------------------------------------------------------------------------
$Tools = @(
    'lazygit', 'neovim', 'yazi', 'wezterm-nightly',
    'fzf', 'ripgrep', 'bat',
    'FiraCode-NF'
)
$Languages = @('python', 'go', 'lua', 'lua51', 'luarocks', 'stylua', 'nodejs-lts')
$Deps      = @('autohotkey', 'gcc', 'cmake', 'fastfetch', 'firacode')

function Install-ScoopPackages($label, $pkgs) {
    Write-Step "Installing $label"
    foreach ($p in $pkgs) {
        $installed = scoop list 2>$null | Select-String -SimpleMatch -Pattern "^$p\s" -Quiet
        if ($installed) {
            Write-Host "  $p already installed"
        } else {
            scoop install $p
            if ($LASTEXITCODE -ne 0) { Write-Warn2 "  failed: $p" }
        }
    }
}

Install-ScoopPackages 'core tools'   $Tools
Install-ScoopPackages 'languages'    $Languages
Install-ScoopPackages 'dependencies' $Deps

# Telescope FZF Native (Neovim) needs a real gcc shim
$gccShim = Join-Path $env:USERPROFILE 'scoop\apps\gcc\current\bin\gcc.exe'
if (Test-Path $gccShim) {
    Write-Step 'Adding gcc shim for Neovim Telescope FZF Native'
    scoop shim add gcc $gccShim 2>$null | Out-Null
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
    'psmux'        = 'psmux'
    'pstop'        = 'pstop'
    'psnet'        = 'psnet'
}
foreach ($t in $CargoTools.Keys) {
    if (Test-Cmd $CargoTools[$t]) {
        Write-Host "  $t already installed ($($CargoTools[$t]) on PATH)"
        continue
    }
    cargo install $t
    if ($LASTEXITCODE -ne 0) { Write-Warn2 "  failed: $t" }
}
Write-Step 'Installing coreutils (windows feature)'
if (Test-Cmd coreutils) {
    Write-Host '  coreutils already installed'
} else {
    cargo install coreutils --features windows
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

# Register graphify skill for every supported coding CLI present on this machine.
if (Test-Cmd graphify) {
    foreach ($platform in @('claude', 'codex', 'opencode')) {
        Write-Step "Registering graphify skill for $platform"
        graphify install --platform $platform 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warn2 "  graphify install --platform $platform failed" }
    }
}

# ---------------------------------------------------------------------------
# 7b) Claude Code companion CLIs (rtk hook)
#     Marketplace plugins (claude-hud, handoff, andrej-karpathy-skills) are
#     declared in common/claude/settings.json and load at Claude Code startup.
# ---------------------------------------------------------------------------
if (-not (Test-Cmd rtk)) {
    Write-Step 'Installing rtk (LLM output compressor + Claude Code hook)'
    cargo install --git https://github.com/rtk-ai/rtk
    if ($LASTEXITCODE -ne 0) { Write-Warn2 '  rtk install failed' }
}
# Note: do not run `rtk init -g` here. The hook, RTK.md, and @RTK.md reference
# are all baked into common/claude/{settings.json,RTK.md,CLAUDE.md} and wired
# by dotter (step 10). Running `rtk init -g` would create real files that block
# dotter's symlinks.

# ---------------------------------------------------------------------------
# 7c) Global npm tools (hostc — Cloudflare-Workers edge tunnel CLI; openwolf — context manager)
# ---------------------------------------------------------------------------
if (Test-Cmd npm) {
    if (-not (Test-Cmd hostc)) {
        Write-Step 'Installing hostc (edge tunnel CLI) via npm'
        npm install -g hostc
        if ($LASTEXITCODE -ne 0) { Write-Warn2 '  hostc install failed' }
    }
    if (-not (Test-Cmd openwolf)) {
        Write-Step 'Installing openwolf via npm'
        npm install -g openwolf
        if ($LASTEXITCODE -ne 0) { Write-Warn2 '  openwolf install failed' }
    }

    # AI coding CLIs (Claude Code / Codex / OpenCode)
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
} else {
    Write-Warn2 'npm not on PATH -- skipping npm-based CLI installs (open a new shell after scoop installs nodejs-lts, then re-run)'
}

# ---------------------------------------------------------------------------
# 7d) pnpm via corepack (ships with Node >= 16.10)
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

# Proxy — applied at the user scope so non-pwsh processes (wezterm plugin
# clones, vscode, etc.) also route through it. The pwsh profile sets the
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
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
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
# 11) WezTerm session state directory.
#     wezterm.lua writes ~/.local/share/wezterm/sessions/ for save/restore;
#     creating it up-front means the lua mkdir fallback never has to run.
# ---------------------------------------------------------------------------
$SessionsDir = Join-Path $env:USERPROFILE '.local\share\wezterm\sessions'
if (-not (Test-Path $SessionsDir)) {
    New-Item -ItemType Directory -Path $SessionsDir -Force | Out-Null
    Write-Host "  created $SessionsDir"
}

Write-Step 'Done. Open a new terminal to pick up the environment.'
Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' graphify: per-project setup' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' For each project where you want a knowledge graph, run:'
Write-Host ''
Write-Host '   cd <your-project>'
Write-Host '   graphify hook install     # auto-rebuild on commit/checkout'
Write-Host '   graphify update .         # initial AST build (no API cost)'
Write-Host ''
Write-Host ' Then in your AI coding CLI (any of these works):'
Write-Host '   claude     # Claude Code     -> /graphify .'
Write-Host '   codex      # OpenAI Codex    -> /graphify .'
Write-Host '   opencode   # OpenCode        -> /graphify .'
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Next: install WSL2 with `wsl --install`, open Ubuntu, then run install-linux.sh inside WSL.' -ForegroundColor DarkGray
