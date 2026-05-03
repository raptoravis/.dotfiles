#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$claudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
$pluginRoot = Join-Path $claudeDir 'plugins\cache\claude-hud\claude-hud'

$latest = Get-ChildItem $pluginRoot -Directory |
    Where-Object { $_.Name -match '^\d+(\.\d+)+$' } |
    Sort-Object { [version]$_.Name } -Descending |
    Select-Object -First 1

if (-not $latest) { exit 0 }

# Claude Code spawns this script with stdout piped, so node sees no TTY and
# claude-hud falls back to a hardcoded width of 40 — splitting every ' | '
# segment onto its own line. Probe the real terminal width and pass it via
# COLUMNS so the wrap stays on 1-2 lines.
$cols = 0
try { $cols = [Console]::WindowWidth } catch {}
if ($cols -le 0) {
    try { $cols = $Host.UI.RawUI.WindowSize.Width } catch {}
}
if ($cols -gt 0) { $env:COLUMNS = $cols }

& 'C:\Program Files\nodejs\node.exe' (Join-Path $latest.FullName 'dist\index.js')
