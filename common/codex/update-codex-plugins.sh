#!/usr/bin/env bash
# update-codex-plugins.sh — 刷新 Codex plugin marketplace 快照并更新已装插件
#
# 与 update-claude-plugins.sh 对称。Codex 提供原生命令：
#   codex plugin marketplace upgrade  # 刷新所有已配置 marketplace 的快照
#   codex plugin add <p>@<m>          # 从快照重新安装（刷新本地缓存）
# 本脚本先 upgrade marketplace，再对 agent-skills 重跑 add 触发缓存刷新。
#
# 依赖：codex CLI。
set -euo pipefail

command -v codex >/dev/null 2>&1 || { echo "找不到 codex CLI" >&2; exit 1; }

echo "==> 刷新所有 marketplace 快照"
codex plugin marketplace upgrade || echo "  (marketplace upgrade 有报错，继续)"

# agent-skills 是本仓库通过 install-* 装入的 Codex plugin；重新 add 以刷新缓存。
echo "==> 刷新 agent-skills 插件缓存"
if codex plugin add agent-skills@agent-skills >/dev/null 2>&1; then
  echo "完成。重启 Codex 生效。"
else
  echo "  agent-skills add 失败（marketplace 是否已配置？）" >&2
  exit 1
fi
