#!/usr/bin/env pwsh
# update-codex-plugins.ps1 — 刷新 Codex plugin marketplace 快照并更新已装插件
#
# 与 update-claude-plugins.ps1 对称。Codex 提供原生命令：
#   codex plugin marketplace upgrade  # 刷新所有已配置 marketplace 的快照
#   codex plugin add <p>@<m>          # 从快照重新安装（刷新本地缓存）
# 本脚本先 upgrade marketplace，再对 agent-skills 重跑 add 触发缓存刷新。
#
# 依赖：codex CLI。
$ErrorActionPreference = 'Stop'

if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
    Write-Error '找不到 codex CLI'
    exit 1
}

Write-Host '==> 刷新所有 marketplace 快照'
codex plugin marketplace upgrade
if ($LASTEXITCODE -ne 0) { Write-Host '  (marketplace upgrade 有报错，继续)' }

# agent-skills 是本仓库通过 install-* 装入的 Codex plugin；重新 add 以刷新缓存。
Write-Host '==> 刷新 agent-skills 插件缓存'
codex plugin add agent-skills@agent-skills 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host '完成。重启 Codex 生效。'
} else {
    Write-Warning '  agent-skills add 失败（marketplace 是否已配置？）'
    exit 1
}
