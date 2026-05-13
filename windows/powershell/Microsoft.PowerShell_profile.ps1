# Microsoft.PowerShell_profile.ps1
# Loaded by $PROFILE (wired by install-windows.ps1).
# Runtime configuration for PowerShell modules installed via PSGallery.

# PSReadLine — predictive intellisense + history dropdown + tab menu
Import-Module PSReadLine
Set-PSReadLineOption -PredictionSource History -PredictionViewStyle ListView
Set-PSReadLineOption -EditMode Windows -HistorySearchCursorMovesToEnd
Set-PSReadLineKeyHandler -Key Tab           -Function MenuComplete
Set-PSReadLineKeyHandler -Key UpArrow       -Function HistorySearchBackward
Set-PSReadLineKeyHandler -Key DownArrow     -Function HistorySearchForward
Set-PSReadLineKeyHandler -Key RightArrow    -Function ForwardChar  # accept inline ghost text

# PSFzf — Ctrl+D file search, Ctrl+R history search.
# Eager: PSFzf registers PSReadLine chord handlers at import time, so it has
# to be loaded before the first keypress. Lazy-loading would miss the chord.
if (Get-Module -ListAvailable -Name PSFzf) {
    Import-Module PSFzf
    Set-PsFzfOption -PSReadLineChordProvider 'Ctrl+d' -PSReadLineChordReverseHistory 'Ctrl+r'
}

# ---------------------------------------------------------------------------
# Lazy module loading — defer non-critical modules until first use.
# Each tab in a wezterm session-restore otherwise serializes on profile
# load; deferring Terminal-Icons / z / git-aliases shaves several hundred
# ms per tab.
# ---------------------------------------------------------------------------

# Terminal-Icons — load on first ls/dir. Once the module is imported,
# Get-ChildItem output is decorated automatically.
if (Get-Module -ListAvailable -Name Terminal-Icons) {
    function ls {
        if (-not (Get-Module Terminal-Icons)) {
            Import-Module Terminal-Icons -ErrorAction SilentlyContinue
        }
        Get-ChildItem @args
    }
}

# z — load on first `z` invocation. Stub removes itself, imports the real
# module, then re-dispatches; subsequent calls hit the module's z directly.
if (Get-Module -ListAvailable -Name z) {
    function z {
        Remove-Item function:z -ErrorAction SilentlyContinue
        Import-Module z -ErrorAction SilentlyContinue
        z @args
    }
}

# git-aliases — module exports >100 aliases (g, ga, gaa, gb, gc, gco, gd,
# gp, gs, gst, ...). Stubbing each one is unmaintainable, so use the
# CommandNotFoundAction hook: when an unknown command starting with g[a-z]
# is invoked, import the module and let the resolver retry.
if (Get-Module -ListAvailable -Name git-aliases) {
    $global:_git_aliases_loaded = $false
    $ExecutionContext.InvokeCommand.CommandNotFoundAction = {
        param([string]$cmdName, [System.Management.Automation.CommandLookupEventArgs]$eventArgs)
        if (-not $global:_git_aliases_loaded -and $cmdName -match '^g[a-z]') {
            Import-Module git-aliases -DisableNameChecking -ErrorAction SilentlyContinue
            $global:_git_aliases_loaded = $true
            $resolved = Get-Command $cmdName -ErrorAction SilentlyContinue
            if ($resolved) {
                $eventArgs.Command = $resolved
                $eventArgs.StopSearch = $true
            }
        }
    }
}

# ---------------------------------------------------------------------------
# User aliases
# ---------------------------------------------------------------------------
Set-Alias vim nvim
Set-Alias vi nvim
Set-Alias ll ls
#Set-Alias llt ls -la
Set-Alias grep findstr
#Set-Alias python3 python
Set-Alias -Name e -Value explorer.exe
Set-Alias -Name lg -Value lazygit
#Set-Alias -Name llt -Value dir -File | sort LastWriteTime -Descending
#Set-Alias -Name llt -Value dir -File | sort LastWriteTime -Ascending

function touch {
    param([Parameter(Mandatory, ValueFromRemainingArguments)] [string[]]$Paths)
    foreach ($p in $Paths) {
        if (Test-Path -LiteralPath $p) {
            (Get-Item -LiteralPath $p).LastWriteTime = Get-Date
        } else {
            New-Item -ItemType File -Path $p | Out-Null
        }
    }
}

function llt {
    #Get-ChildItem -File | Sort-Object LastWriteTime -Descending
    Get-ChildItem | Sort-Object LastWriteTime
}

Set-Alias -Name editor -Value nvim
Set-Alias -Name edit -Value editor

# yazi wrapper — cd to the directory selected on exit
function y {
    $tmp = (New-TemporaryFile).FullName
    yazi.exe @args --cwd-file="$tmp"
    $cwd = Get-Content -Path $tmp -Encoding UTF8
    if ($cwd -and $cwd -ne $PWD.Path -and (Test-Path -LiteralPath $cwd -PathType Container)) {
        Set-Location -LiteralPath (Resolve-Path -LiteralPath $cwd).Path
    }
    Remove-Item -Path $tmp
}

function profile_alias { editor $PROFILE }
Set-Alias -Name profile -Value profile_alias

function reload_alias { & $PROFILE }
Set-Alias -Name reload -Value reload_alias

# ---------------------------------------------------------------------------
# Navigation: goto <shortcut>
# ---------------------------------------------------------------------------
function goto {
    param (
        $location
    )

    Switch ($location) {
        "torex" {
            Set-Location -Path "D:\dev\torex.git"
        }
        "dev" {
            Set-Location -Path "D:\dev"
        }
        "dl" {
            Set-Location -Path "E:\downloads"
        }
        "programs" {
            Set-Location -Path "E:\downloads\weiyun\disk\latest\programs"
        }
        "fav" {
            Set-Location -Path "E:\downloads\weiyun\disk\latest\dev\fav"
        }
        "nvim" {
            Set-Location -Path "$HOME\AppData\Local\nvim"
        }
        default {
            Write-Output "possible argments: torex/dev/dl/programs/fav"
        }
    }
}

#Set-Alias gt goto
#Set-Alias g goto

# ---------------------------------------------------------------------------
# Git helpers (override / extend git-aliases module)
# ---------------------------------------------------------------------------
#Set-Alias -Name gac -Value gaa && gcam
function gac {
    param (
        $p
    )

    gaa
    gcam $p
}

#Set-Alias -Name gpa -Value gp && gp gh
function gpa {
    git push
    git push gh
    #git push gl
}

# ---------------------------------------------------------------------------
# dotter wrapper — downgrade "already exists. Skipping." [ERROR] to [WARN ].
# Call dotter.exe explicitly to avoid recursing into this function.
# ---------------------------------------------------------------------------
function dotter {
    $softErrorPattern = 'already exists\. Skipping\.|Some files were skipped\.'
    & dotter.exe @args 2>&1 | ForEach-Object {
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
}

# ---------------------------------------------------------------------------
# Conda environment helpers
# ---------------------------------------------------------------------------
function pve {
    param (
        $env_name
    )

    conda activate $env_name
}

function pved {
    conda deactivate
}

# ---------------------------------------------------------------------------
# Proxy (Clash / mihomo default port 7890)
# Comment out `proxy_on` below to disable auto-enable; use proxy_on / proxy_off
# to toggle at runtime.
# ---------------------------------------------------------------------------
$env:PROXY_URL = 'http://127.0.0.1:7890'

function proxy_on {
    $env:HTTP_PROXY  = $env:PROXY_URL
    $env:HTTPS_PROXY = $env:PROXY_URL
    $env:ALL_PROXY   = $env:PROXY_URL
}

function proxy_off {
    Remove-Item Env:HTTP_PROXY, Env:HTTPS_PROXY, Env:ALL_PROXY -ErrorAction SilentlyContinue
}

proxy_on

# ---------------------------------------------------------------------------
# uv (Python) — China mirrors
# ---------------------------------------------------------------------------
#$env:UV_PYTHON_INSTALL_MIRROR="https://ghproxy.cn/https://github.com/indygreg/python-build-standalone/releases/download"
#$env:UV_INDEX_URL="https://repo.huaweicloud.com/repository/pypi/simple/"
#$env:UV_EXTRA_INDEX_URL="https://pypi.tuna.tsinghua.edu.cn/simple/"
#$env:UV_EXTRA_INDEX_URL="https://mirrors.aliyun.com/pypi/simple/"
#$env:UV_EXTRA_INDEX_URL="https://pypi.org/simple/"
$env:UV_INDEX_URL = "https://pypi.tuna.tsinghua.edu.cn/simple/"
$env:UV_LINK_MODE = "copy"

#$env:ANTHROPIC_API_KEY="sk-d86c08e38dce47fda2bfbcd6671ac6de"
#$env:ANTHROPIC_BASE_URL="http://127.0.0.1:8045"

#$env:OLLAMA_HOST="127.0.0.1:8181"

# ---------------------------------------------------------------------------
# Starship prompt — must run before the prompt wrapper below so Set-Title
# can wrap starship's `prompt` function.
# ---------------------------------------------------------------------------
if (Get-Command starship -ErrorAction SilentlyContinue) {
    Invoke-Expression (& starship init powershell)
}

# ---------------------------------------------------------------------------
# Window title — git repo root if inside one, else current path.
# Hooked into prompt so the title refreshes on every directory change.
# ---------------------------------------------------------------------------
function Set-Title() {
    # Preserve $LASTEXITCODE so the user's command status survives the git call.
    $origLEC = $global:LASTEXITCODE
    $repo = git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $repo) {
        $repo = (Get-Location).Path
    }
    $host.UI.RawUI.WindowTitle = $repo
    $global:LASTEXITCODE = $origLEC
}

# Wrap the existing prompt (default PowerShell prompt, or whatever was set
# upstream) so Set-Title runs on every prompt redraw.
$Script:_origPrompt = (Get-Command prompt -ErrorAction SilentlyContinue).ScriptBlock
function prompt {
    Set-Title
    # Sync the .NET process cwd with the PSDrive location. Set-Location only
    # updates Get-Location; child processes (starship) inherit the unchanged
    # .NET cwd, which breaks starship's relative python_binary lookup against
    # .venv/Scripts/python.exe (the prompt would show the system python).
    $loc = $executionContext.SessionState.Path.CurrentLocation
    if ($loc.Provider.Name -eq 'FileSystem') {
        [System.IO.Directory]::SetCurrentDirectory($loc.ProviderPath)
    }
    if ($Script:_origPrompt) {
        & $Script:_origPrompt
    } else {
        "PS $($executionContext.SessionState.Path.CurrentLocation)$('>' * ($nestedPromptLevel + 1)) "
    }
}
