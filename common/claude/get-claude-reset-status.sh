#!/usr/bin/env bash
# get-claude-reset-status.sh — 查询 Claude 订阅的 5h / weekly 用量窗口 reset 时间（响应头方案）
#
# 思路：用 ~/.claude/settings.json 里的 OAuth token 调一次 /v1/messages（max_tokens=1），
# 从响应头 anthropic-ratelimit-unified-* 里读 reset。
# OAuth (Max/Pro) token 只允许 Claude Code 风格请求，所以 system 必须伪装成 Claude Code，否则 403。
# 这会消耗一点点你的 5h/weekly 额度（1 次极小请求）。
#
# 依赖：curl + (jq 或 python3)，GNU date（WSL/Linux/mac+coreutils）。
set -euo pipefail

MODEL="${CLAUDE_RESET_MODEL:-claude-haiku-4-5}"
DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

get_token() {
  if [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then printf '%s' "$ANTHROPIC_AUTH_TOKEN"; return 0; fi
  if [ -n "${ANTHROPIC_API_KEY:-}" ];    then printf '%s' "$ANTHROPIC_API_KEY";    return 0; fi
  if command -v jq >/dev/null 2>&1; then
    if [ -f "$DIR/settings.json" ]; then
      t=$(jq -r '.env.ANTHROPIC_AUTH_TOKEN // empty' "$DIR/settings.json")
      [ -n "$t" ] && { printf '%s' "$t"; return 0; }
    fi
    if [ -f "$DIR/.credentials.json" ]; then
      t=$(jq -r '.claudeAiOauth.accessToken // empty' "$DIR/.credentials.json")
      [ -n "$t" ] && { printf '%s' "$t"; return 0; }
    fi
  elif command -v python3 >/dev/null 2>&1; then
    t=$(python3 - "$DIR" <<'PY'
import json, os, sys
d = sys.argv[1]
for f, keys in [("settings.json", ["env", "ANTHROPIC_AUTH_TOKEN"]),
                (".credentials.json", ["claudeAiOauth", "accessToken"])]:
    try:
        o = json.load(open(os.path.join(d, f)))
        for k in keys:
            o = o[k]
        if o:
            print(o)
            break
    except Exception:
        pass
PY
)
    [ -n "$t" ] && { printf '%s' "$t"; return 0; }
  fi
  return 1
}

TOKEN="$(get_token)" || { echo "找不到 auth token (settings.json env.ANTHROPIC_AUTH_TOKEN / .credentials.json / 环境变量)" >&2; exit 1; }

HDR_FILE="$(mktemp)"
trap 'rm -f "$HDR_FILE"' EXIT

BODY=$(cat <<JSON
{"model":"$MODEL","max_tokens":1,"system":[{"type":"text","text":"You are Claude Code, Anthropic's official CLI for Claude."}],"messages":[{"role":"user","content":"x"}]}
JSON
)

CODE=$(curl -sS -o /dev/null -D "$HDR_FILE" -w '%{http_code}' \
  -H "authorization: Bearer $TOKEN" \
  -H "anthropic-version: 2023-06-01" \
  -H "anthropic-beta: oauth-2025-04-20" \
  -H "content-type: application/json" \
  -X POST "https://api.anthropic.com/v1/messages" \
  -d "$BODY") || { echo "请求失败" >&2; exit 1; }

echo "HTTP $CODE"
echo ""
echo "=== 原始 rate-limit 响应头 ==="
grep -i 'ratelimit' "$HDR_FILE" | tr -d '\r' || echo "(无 ratelimit 头)"

get_h() { grep -i "^$1:" "$HDR_FILE" | head -1 | sed "s/^[^:]*:[[:space:]]*//" | tr -d '\r'; }

to_local() {
  v="$1"
  case "$v" in
    ''|*[!0-9]*) date -d "$v" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$v" ;;
    *)
      n="$v"
      [ "${#v}" -ge 13 ] && n=$((v / 1000))
      date -d "@$n" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$v"
      ;;
  esac
}

fmt_pct() {
  [ -z "$1" ] && return
  awk -v u="$1" 'BEGIN { printf "  用量 %d%%", u*100 + 0.5 }'
}

echo ""
echo "=== 解析 ==="
FIVE=$(get_h "anthropic-ratelimit-unified-5h-reset")
FIVE_U=$(get_h "anthropic-ratelimit-unified-5h-utilization")
WEEK=$(get_h "anthropic-ratelimit-unified-7d-reset")
WEEK_U=$(get_h "anthropic-ratelimit-unified-7d-utilization")
if [ -n "$FIVE" ]; then echo "5 小时窗口 reset: $(to_local "$FIVE")$(fmt_pct "$FIVE_U")"; else echo "5 小时窗口 reset: (头里没有，看上面原始头确认实际名字)"; fi
if [ -n "$WEEK" ]; then echo "每周窗口 reset:  $(to_local "$WEEK")$(fmt_pct "$WEEK_U")"; else echo "每周窗口 reset:  (头里没有，看上面原始头确认实际名字)"; fi
