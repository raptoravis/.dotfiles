#!/usr/bin/env pwsh
# get-claude-reset-status.ps1 — 查询 Claude 订阅的 5h / weekly 用量窗口 reset 时间（响应头方案）
#
# 思路：用 ~/.claude/settings.json 里的 OAuth token 调一次 /v1/messages（max_tokens=1），
# 从响应头 anthropic-ratelimit-unified-* 里读 reset。
# 注意：OAuth (Max/Pro) token 只允许 Claude Code 风格的请求，所以 system 必须伪装成 Claude Code，
# 否则会 403。这会消耗一点点你的 5h/weekly 额度（1 次极小请求）。
#
# 需要 PowerShell 7+ (pwsh)。
[CmdletBinding()]
param(
  [string]$Model = "claude-haiku-4-5"
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

function Get-AuthToken {
  if ($env:ANTHROPIC_AUTH_TOKEN) { return $env:ANTHROPIC_AUTH_TOKEN.Trim() }
  if ($env:ANTHROPIC_API_KEY)    { return $env:ANTHROPIC_API_KEY.Trim() }
  $dir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME ".claude" }
  $settings = Join-Path $dir "settings.json"
  if (Test-Path $settings) {
    $tok = (Get-Content $settings -Raw | ConvertFrom-Json).env.ANTHROPIC_AUTH_TOKEN
    if ($tok) { return "$tok".Trim() }
  }
  $cred = Join-Path $dir ".credentials.json"
  if (Test-Path $cred) {
    $tok = (Get-Content $cred -Raw | ConvertFrom-Json).claudeAiOauth.accessToken
    if ($tok) { return "$tok".Trim() }
  }
  throw "找不到 auth token (settings.json env.ANTHROPIC_AUTH_TOKEN / .credentials.json / 环境变量)"
}

function Convert-ResetValue($v) {
  if (-not $v) { return $null }
  $s = "$v"
  if ($s -match '^\d+$') {
    $n = [int64]$s
    if ($n -gt 1e12) { return [DateTimeOffset]::FromUnixTimeMilliseconds($n).LocalDateTime }
    return [DateTimeOffset]::FromUnixTimeSeconds($n).LocalDateTime
  }
  try { return ([DateTimeOffset]::Parse($s)).LocalDateTime } catch { return $s }
}

$token = Get-AuthToken

$headers = @{
  "authorization"     = "Bearer $token"
  "anthropic-version" = "2023-06-01"
  "anthropic-beta"    = "oauth-2025-04-20"
  "content-type"      = "application/json"
}

$body = @{
  model      = $Model
  max_tokens = 1
  system     = @(@{ type = "text"; text = "You are Claude Code, Anthropic's official CLI for Claude." })
  messages   = @(@{ role = "user"; content = "x" })
} | ConvertTo-Json -Depth 6

$resp = Invoke-WebRequest -Uri "https://api.anthropic.com/v1/messages" `
  -Method Post -Headers $headers -Body $body -SkipHttpErrorCheck

if ($resp.StatusCode -ne 200) {
  Write-Host "HTTP $($resp.StatusCode)" -ForegroundColor Yellow
  Write-Host $resp.Content
}

$rl = $resp.Headers.GetEnumerator() | Where-Object { $_.Key -match 'ratelimit' } | Sort-Object Key
if (-not $rl) {
  Write-Host "响应里没有 ratelimit 头（状态码 $($resp.StatusCode)）。" -ForegroundColor Red
  exit 1
}

Write-Host "`n=== 原始 rate-limit 响应头 ===" -ForegroundColor Cyan
foreach ($h in $rl) { "{0,-46} {1}" -f $h.Key, ($h.Value -join ", ") }

function Get-Header($name) {
  $h = $resp.Headers[$name]
  if ($h) { return ($h -join ",") }
  return $null
}

function Format-Pct($u) {
  if (-not $u) { return "" }
  $n = 0.0
  if ([double]::TryParse("$u", [ref]$n)) { return ("  用量 {0:0}%" -f ($n * 100)) }
  return ""
}

function Show-Reset($label, $reset, $util) {
  $pct = Format-Pct $util
  if (-not $reset) { Write-Host ("{0}: (头里没有该字段，看上面原始头确认实际名字){1}" -f $label, $pct) -ForegroundColor DarkGray; return }
  if ($reset -is [datetime]) {
    $left = $reset - (Get-Date)
    if ($left.Ticks -lt 0) { $left = [TimeSpan]::Zero }
    "{0}: {1:yyyy-MM-dd HH:mm:ss}  (还剩 {2}h{3}m){4}" -f $label, $reset, [int]$left.TotalHours, $left.Minutes, $pct
  } else {
    "{0}: {1}{2}" -f $label, $reset, $pct
  }
}

Write-Host "`n=== 解析 ===" -ForegroundColor Cyan
Show-Reset "5 小时窗口 reset" (Convert-ResetValue (Get-Header "anthropic-ratelimit-unified-5h-reset")) (Get-Header "anthropic-ratelimit-unified-5h-utilization")
Show-Reset "每周窗口  reset" (Convert-ResetValue (Get-Header "anthropic-ratelimit-unified-7d-reset")) (Get-Header "anthropic-ratelimit-unified-7d-utilization")
