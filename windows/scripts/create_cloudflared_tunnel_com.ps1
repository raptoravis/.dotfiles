#Requires -Version 5.1
<#
.SYNOPSIS
    一键创建 / 更新 cloudflared named tunnel：建 tunnel、route DNS、生成 config.yml。

.PARAMETER TunnelName
    Tunnel 名字，例如 "home"。已存在则复用，不存在则创建。

.PARAMETER Routes
    Hashtable: hostname -> 本地服务 URL。例如:
      @{ 'app.example.com' = 'http://localhost:3000'; 'api.example.com' = 'http://localhost:8080' }

.PARAMETER HaConnections
    HA 连接数。免费版服务端硬上限 2，默认 2。

.PARAMETER ConfigPath
    config.yml 路径。默认 ~/.cloudflared/config.yml。

.PARAMETER Force
    config.yml 已存在时强制覆盖。否则同名文件存在会报错退出。

.EXAMPLE
    .\create_cloudflared_tunnel.ps1 -TunnelName home -Routes @{
        'haishan.ccwu.cc'  = 'http://localhost:5173'
        'tunan.ccwu.cc'    = 'http://localhost:9280'
        'tianyun.ccwu.cc'  = 'http://localhost:5006'
    }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TunnelName = "com",

    [hashtable]$Routes = @{
        'haishan.ccwu.cc' = 'http://localhost:5173'
        'peifeng.ccwu.cc'   = 'http://localhost:9280'
        'yunxing.ccwu.cc' = 'http://localhost:3000'
    },

    [int]$HaConnections = 2,

    [string]$ConfigPath = (Join-Path $env:USERPROFILE '.cloudflared\config.yml'),

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Require-Command($name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "$name 未安装或不在 PATH。请先 ``scoop install cloudflared``。"
    }
}

function Get-TunnelUuid([string]$name) {
    $line = cloudflared tunnel list 2>$null |
        Select-String -Pattern "^([0-9a-f-]{36})\s+$([regex]::Escape($name))\s"
    if ($line) { return $line.Matches[0].Groups[1].Value }
    return $null
}

Require-Command cloudflared

$cloudflaredDir = Join-Path $env:USERPROFILE '.cloudflared'
if (-not (Test-Path $cloudflaredDir)) {
    New-Item -ItemType Directory -Path $cloudflaredDir | Out-Null
}

if (-not (Test-Path (Join-Path $cloudflaredDir 'cert.pem'))) {
    Write-Host '== cert.pem 不存在，启动浏览器登录授权 ==' -ForegroundColor Cyan
    cloudflared tunnel login
    if ($LASTEXITCODE -ne 0) { throw 'cloudflared tunnel login 失败' }
}

$uuid = Get-TunnelUuid $TunnelName
if ($uuid) {
    Write-Host "== Tunnel '$TunnelName' 已存在 (UUID: $uuid)，复用 ==" -ForegroundColor Yellow
} else {
    Write-Host "== 创建 tunnel '$TunnelName' ==" -ForegroundColor Cyan
    cloudflared tunnel create $TunnelName
    if ($LASTEXITCODE -ne 0) { throw "cloudflared tunnel create 失败" }
    $uuid = Get-TunnelUuid $TunnelName
    if (-not $uuid) { throw "创建后仍找不到 tunnel '$TunnelName'" }
}

$credsFile = Join-Path $cloudflaredDir "$uuid.json"
if (-not (Test-Path $credsFile)) {
    throw "凭证文件不存在: $credsFile（tunnel 创建可能未完成？）"
}

Write-Host '== 配置 DNS 路由 ==' -ForegroundColor Cyan
$dnsIssues = @()
foreach ($hostname in $Routes.Keys) {
    Write-Host "  -> $hostname"
    cloudflared tunnel route dns $TunnelName $hostname
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "route dns 退出码非零: $hostname"
    }

    # 验证 DNS 是否真的写入：DoH 查 A 记录，proxied CNAME 应返回 CF anycast IP
    Start-Sleep -Seconds 2
    try {
        $resp = Invoke-RestMethod -Uri "https://1.1.1.1/dns-query?name=$hostname&type=A" `
            -Headers @{ 'accept' = 'application/dns-json' } -TimeoutSec 5
        if (-not $resp.Answer) {
            $dnsIssues += $hostname
        }
    } catch {
        Write-Warning "DoH 验证 $hostname 失败：$($_.Exception.Message)"
    }
}

if ($dnsIssues.Count -gt 0) {
    Write-Warning ''
    Write-Warning '以下 hostname 的 DNS 记录未真正写入（cloudflared 可能误报 "already configured"）：'
    $dnsIssues | ForEach-Object { Write-Warning "    $_" }
    Write-Warning ''
    Write-Warning '修复办法：进入 dashboard 对应 zone -> DNS -> Records，手动加 CNAME：'
    Write-Warning "    Type: CNAME"
    Write-Warning "    Name: @"
    Write-Warning "    Target: $uuid.cfargotunnel.com"
    Write-Warning "    Proxy: Proxied (橙云)"
}

if ((Test-Path $ConfigPath) -and -not $Force) {
    throw "$ConfigPath 已存在。加 -Force 覆盖，或手动备份后重试。"
}

Write-Host "== 写入 $ConfigPath ==" -ForegroundColor Cyan

$credsForwardSlash = $credsFile -replace '\\', '/'
$lines = @(
    "tunnel: $TunnelName"
    "credentials-file: `"$credsForwardSlash`""
    "ha-connections: $HaConnections"
    ''
    'ingress:'
)
foreach ($hostname in $Routes.Keys) {
    $lines += "  - hostname: $hostname"
    $lines += "    service: $($Routes[$hostname])"
}
$lines += '  # 兜底必须有，且必须是最后一条'
$lines += '  - service: http_status:404'
$lines += ''

Set-Content -Path $ConfigPath -Value $lines -Encoding UTF8

Write-Host ''
Write-Host '完成。下一步：' -ForegroundColor Green
Write-Host "  cloudflared tunnel run $TunnelName"
Write-Host '或装成 Windows 服务（管理员 PowerShell）：'
Write-Host '  cloudflared service install'
