#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$claudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
$pluginRoot = Join-Path $claudeDir 'plugins\cache\claude-hud\claude-hud'

$latest = Get-ChildItem $pluginRoot -Directory |
    Where-Object { $_.Name -match '^\d+(\.\d+)+$' } |
    Sort-Object { [version]$_.Name } -Descending |
    Select-Object -First 1

if (-not $latest) { exit 0 }

& 'C:\Program Files\nodejs\node.exe' (Join-Path $latest.FullName 'dist\index.js')
