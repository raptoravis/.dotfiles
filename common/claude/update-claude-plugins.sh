#!/usr/bin/env bash
# update-claude-plugins.sh — 更新所有 Claude Code marketplace 与已安装插件
#
# Claude CLI 没有 "update all plugins" 命令，只有：
#   claude plugin marketplace update        # 刷新所有 marketplace catalog
#   claude plugin update <plugin> [--scope] # 单个插件
# 本脚本先刷 marketplace，再从 `claude plugin list --json` 遍历逐个更新。
#
# 依赖：claude CLI + (jq 或 python3)。
set -euo pipefail

command -v claude >/dev/null 2>&1 || { echo "找不到 claude CLI" >&2; exit 1; }

echo "==> 更新所有 marketplace"
claude plugin marketplace update || echo "  (marketplace 更新有报错，继续)"

# 输出形如：<id> <scope>，每行一个插件
list_plugins() {
  local json
  json="$(claude plugin list --json)"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r '.[] | "\(.id)\t\(.scope)"'
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$json" | python3 -c 'import json,sys
for p in json.load(sys.stdin):
    print(f"{p[\"id\"]}\t{p.get(\"scope\",\"user\")}")'
  else
    echo "需要 jq 或 python3 来解析插件列表" >&2
    return 1
  fi
}

ok=0; fail=0
while IFS=$'\t' read -r id scope; do
  [ -n "$id" ] || continue
  echo "==> 更新 $id (scope=$scope)"
  if claude plugin update "$id" --scope "$scope"; then
    ok=$((ok + 1))
  else
    echo "  更新失败：$id" >&2
    fail=$((fail + 1))
  fi
done < <(list_plugins)

echo ""
echo "完成：成功 $ok 个，失败 $fail 个。重启 Claude Code 生效。"
