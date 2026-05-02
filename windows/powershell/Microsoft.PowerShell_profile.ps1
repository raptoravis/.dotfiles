# Microsoft.PowerShell_profile.ps1
# Loaded by $PROFILE (wired by install-windows.ps1).
# Runtime configuration for PowerShell modules installed via PSGallery.

# PSReadLine — predictive intellisense
Import-Module PSReadLine
Set-PSReadLineOption -PredictionSource HistoryAndPlugin -PredictionViewStyle ListView

# PowerType — context-aware completions
if (Get-Module -ListAvailable -Name PowerType) {
    Import-Module PowerType
    Enable-PowerType
}

# PSFzf — Ctrl+D file search, Ctrl+R history search
if (Get-Module -ListAvailable -Name PSFzf) {
    Import-Module PSFzf
    Set-PsFzfOption -PSReadLineChordProvider 'Ctrl+d' -PSReadLineChordReverseHistory 'Ctrl+r'
}

# Terminal-Icons — file/folder glyphs in ls output
if (Get-Module -ListAvailable -Name Terminal-Icons) {
    Import-Module Terminal-Icons
}

# z — frecency-based directory jumper
if (Get-Module -ListAvailable -Name z) {
    Import-Module z
}

# git-aliases — short git command aliases (g, gs, gc, ...)
if (Get-Module -ListAvailable -Name git-aliases) {
    Import-Module git-aliases -DisableNameChecking
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
#Set-Alias -Name llt -Value dir -File | sort LastWriteTime -Descending
#Set-Alias -Name llt -Value dir -File | sort LastWriteTime -Ascending

function llt {
    #Get-ChildItem -File | Sort-Object LastWriteTime -Descending
    Get-ChildItem | Sort-Object LastWriteTime
}

Set-Alias -Name editor -Value nvim
Set-Alias -Name edit -Value editor

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
    if ($Script:_origPrompt) {
        & $Script:_origPrompt
    } else {
        "PS $($executionContext.SessionState.Path.CurrentLocation)$('>' * ($nestedPromptLevel + 1)) "
    }
}
