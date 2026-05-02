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
    [string]$DotfilesDir = (Join-Path $env:USERPROFILE '.dotfiles')
)

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
Write-Step 'Adding Scoop buckets (extras, nerd-fonts)'
scoop bucket add extras     2>$null | Out-Null
scoop bucket add nerd-fonts 2>$null | Out-Null

# ---------------------------------------------------------------------------
# 3) Core tools, languages, dependencies (matches Makefile.toml `windows-tools`)
# ---------------------------------------------------------------------------
$Tools = @(
    'lazygit', 'neovim', 'yazi', 'wezterm-nightly',
    'fzf', 'ripgrep', 'bat', 'yasb', 'FiraCode-NF'
)
$Languages = @('python', 'go', 'lua', 'lua51', 'luarocks', 'stylua')
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
    rustup component add clippy rustfmt 2>$null | Out-Null
}

# ---------------------------------------------------------------------------
# 6) Cargo tools
# ---------------------------------------------------------------------------
Write-Step 'Installing Cargo tools'
$CargoTools = @('dotter', 'cargo-update', 'vivid', 'eza', 'bottom', 'bat', 'mise')
foreach ($t in $CargoTools) {
    cargo install $t
    if ($LASTEXITCODE -ne 0) { Write-Warn2 "  failed: $t" }
}
Write-Step 'Installing coreutils (windows feature)'
cargo install coreutils --features windows
if ($LASTEXITCODE -ne 0) { Write-Warn2 '  failed: coreutils' }

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
    'PowerType',
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
    Get-Content $UvFile | Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object {
        uv tool install $_ 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Warn2 "  skip $_ (already installed or failed)" }
    }
}

# ---------------------------------------------------------------------------
# 7b) Claude Code companion CLIs (rtk hook, graphify skill)
#     Marketplace plugins (claude-hud, handoff, andrej-karpathy-skills) are
#     declared in common/claude/settings.json and load at Claude Code startup.
# ---------------------------------------------------------------------------
if (-not (Test-Cmd rtk)) {
    Write-Step 'Installing rtk (LLM output compressor + Claude Code hook)'
    cargo install --git https://github.com/rtk-ai/rtk
    if ($LASTEXITCODE -ne 0) { Write-Warn2 '  rtk install failed' }
}
if (Test-Cmd rtk) {
    Write-Step 'Wiring rtk into Claude Code (rtk init -g)'
    rtk init -g
    if ($LASTEXITCODE -ne 0) { Write-Warn2 '  rtk init -g failed' }
}

if (Test-Cmd graphify) {
    Write-Step 'Registering graphify skill with Claude Code'
    graphify claude install
    if ($LASTEXITCODE -ne 0) { Write-Warn2 '  graphify claude install failed' }
}

# ---------------------------------------------------------------------------
# 8) Environment variables (XDG_CONFIG_HOME, YAZI_CONFIG_HOME)
# ---------------------------------------------------------------------------
Write-Step 'Setting user environment variables'
[Environment]::SetEnvironmentVariable('XDG_CONFIG_HOME', "$env:USERPROFILE\.config",      'User')
[Environment]::SetEnvironmentVariable('YAZI_CONFIG_HOME', "$env:USERPROFILE\.config\yazi", 'User')

# ---------------------------------------------------------------------------
# 9) Symlinks via dotter
# ---------------------------------------------------------------------------
if (Test-Cmd dotter) {
    Write-Step 'Symlinking dotfiles via dotter'
    Push-Location $DotfilesDir
    try { dotter -v } catch { Write-Warn2 "dotter exited with errors: $_" }
    Pop-Location
} else {
    Write-Warn2 'dotter not on PATH — open a new shell so cargo bin is loaded, then re-run.'
}

Write-Step 'Done. Open a new terminal to pick up the environment.'
Write-Host ''
Write-Host 'Next: install WSL2 with `wsl --install`, open Ubuntu, then run install-linux.sh inside WSL.' -ForegroundColor DarkGray
