#!/usr/bin/env pwsh
# update-claude-plugins.ps1 — 更新所有 Claude Code marketplace 与已安装插件
#
# Claude CLI 没有 "update all plugins" 命令，只有：
#   claude plugin marketplace update        # 刷新所有 marketplace catalog
#   claude plugin update <plugin> [--scope] # 单个插件
# 本脚本先刷 marketplace，再从 `claude plugin list --json` 遍历逐个更新。
#
# 依赖：claude CLI。
$ErrorActionPreference = 'Stop'

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Error '找不到 claude CLI'
    exit 1
}

Write-Host '==> 更新所有 marketplace'
claude plugin marketplace update
if ($LASTEXITCODE -ne 0) { Write-Host '  (marketplace 更新有报错，继续)' }

$plugins = claude plugin list --json | ConvertFrom-Json

$ok = 0; $fail = 0
foreach ($p in $plugins) {
    $scope = if ($p.scope) { $p.scope } else { 'user' }
    Write-Host "==> 更新 $($p.id) (scope=$scope)"
    claude plugin update $p.id --scope $scope
    if ($LASTEXITCODE -eq 0) {
        $ok++
    } else {
        Write-Warning "  更新失败：$($p.id)"
        $fail++
    }
}

Write-Host ''
Write-Host "完成：成功 $ok 个，失败 $fail 个。重启 Claude Code 生效。"
