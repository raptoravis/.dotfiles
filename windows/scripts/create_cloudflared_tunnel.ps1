#Requires -Version 5.1
<#
.SYNOPSIS
    Create / update a cloudflared named tunnel (pure local config mode).
    Builds the tunnel, routes DNS, writes config.yml. Optionally cleans up
    stale state and installs the Windows service.

.PARAMETER Preset
    Required. Which tunnel to manage: com or home.
    Preset bundle (TunnelName + Routes).
    Passing -TunnelName / -Routes overrides the corresponding preset field.

.PARAMETER TunnelName
    Tunnel name. Defaults from -Preset.

.PARAMETER Routes
    Hashtable: hostname -> local service URL. Defaults from -Preset.

.PARAMETER HaConnections
    HA connection count. Free-tier server-side hard cap is 2. Default 2.

.PARAMETER ConfigPath
    config.yml path. Default ~/.cloudflared/config.yml.

.PARAMETER Force
    Overwrite existing config.yml.

.PARAMETER InstallService
    After config.yml is written, install the Windows service using that
    config (requires elevated PowerShell).

.PARAMETER Cleanup
    Before creating: stop & uninstall any existing cloudflared service,
    remove the EventLog registry key, back up the existing config.yml.
    Does NOT touch cert.pem or credentials JSON files.
    To delete the remote tunnel as well, also pass -DeleteRemoteTunnel.

.PARAMETER DeleteRemoteTunnel
    Use with -Cleanup. Deletes -TunnelName from Cloudflare AND removes the
    local credentials JSON. Use when migrating a tunnel to another machine
    or for a fully clean rebuild.

.EXAMPLE
    # This machine: run "com" (cleanup, build/reuse, install service)
    .\create_cloudflared_tunnel.ps1 -Preset com -Cleanup -InstallService

.EXAMPLE
    # Other machine: run "home"
    .\create_cloudflared_tunnel.ps1 -Preset home -InstallService

.EXAMPLE
    # Override one route
    .\create_cloudflared_tunnel.ps1 -Preset com -Routes @{
        'haishan.ccwu.cc' = 'http://localhost:5174'
    }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('com', 'home')]
    [string]$Preset,

    [string]$TunnelName,

    [hashtable]$Routes,

    [int]$HaConnections = 2,

    [string]$ConfigPath = (Join-Path $env:USERPROFILE '.cloudflared\config.yml'),

    [switch]$Force,
    [switch]$InstallService,
    [switch]$Cleanup,
    [switch]$DeleteRemoteTunnel
)

$ErrorActionPreference = 'Stop'

# ----- presets -----
$presets = @{
    com  = @{
        TunnelName = 'com'
        Routes     = @{
            'haishan.ccwu.cc' = 'http://localhost:7861'
            'yunxing.ccwu.cc' = 'http://localhost:6534'
            'tunan.ccwu.cc'   = 'http://localhost:37856'
        }
    }
    home = @{
        TunnelName = 'home'
        Routes     = @{
            'tianyun.ccwu.cc' = 'http://127.0.0.1:50876'
            'peifeng.ccwu.cc' = 'http://localhost:39287'
        }
    }
}

if (-not $TunnelName) { $TunnelName = $presets[$Preset].TunnelName }
if (-not $Routes)     { $Routes     = $presets[$Preset].Routes }

# ----- helpers -----
function Require-Command($name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "$name not found in PATH. Install with: scoop install cloudflared"
    }
}

function Get-TunnelUuid([string]$name) {
    $line = cloudflared tunnel list 2>$null |
        Select-String -Pattern "^([0-9a-f-]{36})\s+$([regex]::Escape($name))\s"
    if ($line) { return $line.Matches[0].Groups[1].Value }
    return $null
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Probe whether Cloudflare's edge can complete a TLS handshake for $hostname.
# A separate sub-zone (e.g. tunan.ccwu.cc registered as its own zone) gets its
# own Universal SSL cert that may not be issued yet; until then CF closes the
# connection mid-handshake and browsers show ERR_EMPTY_RESPONSE even though DNS
# and the tunnel are fine. Returns $true on success, $false on handshake failure.
function Test-EdgeTls([string]$hostname) {
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $tcp.Connect($hostname, 443)
        $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, ({ $true }))
        $ssl.AuthenticateAsClient($hostname)
        $ssl.Close()
        return $true
    } catch {
        return $false
    } finally {
        $tcp.Close()
    }
}

# Run a native command without letting its stderr (cloudflared writes INF logs there)
# trip $ErrorActionPreference='Stop'. Returns the native exit code.
function Invoke-NativeQuiet {
    param([scriptblock]$Block)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Block 2>&1 | ForEach-Object { Write-Host $_ }
    } finally {
        $ErrorActionPreference = $prev
    }
    return $LASTEXITCODE
}

Require-Command cloudflared

$cloudflaredDir = Join-Path $env:USERPROFILE '.cloudflared'
if (-not (Test-Path $cloudflaredDir)) {
    New-Item -ItemType Directory -Path $cloudflaredDir | Out-Null
}

# ----- cleanup -----
if ($Cleanup) {
    Write-Host '== Cleanup ==' -ForegroundColor Cyan

    if (-not (Test-IsAdmin)) {
        Write-Warning 'Not running as Administrator. service uninstall may fail.'
    }

    $svc = Get-Service cloudflared -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Host "  stopping & uninstalling cloudflared service (current: $($svc.Status))"
        # Stop-Service hangs against the empty `cloudflared.exe` process; kill instead.
        Stop-Process -Name cloudflared -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        # `cloudflared service uninstall` is just `sc delete` under the hood.
        sc.exe delete cloudflared | Out-Host
    } else {
        Write-Host '  no cloudflared service, skipping'
    }

    # cloudflared does not clean its EventLog registry key; leftovers cause
    # "registry key already exists" warnings on the next install.
    $evtKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\Cloudflared'
    if (Test-Path $evtKey) {
        Write-Host "  removing EventLog registry key $evtKey"
        Remove-Item $evtKey -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path $ConfigPath) {
        $bak = "$ConfigPath.bak.$(Get-Date -Format yyyyMMddHHmmss)"
        Write-Host "  backing up old config.yml -> $bak"
        Move-Item $ConfigPath $bak
    }

    if ($DeleteRemoteTunnel) {
        $existing = Get-TunnelUuid $TunnelName
        if ($existing) {
            Write-Host "  deleting remote tunnel '$TunnelName' (UUID: $existing)"
            Invoke-NativeQuiet { cloudflared tunnel delete -f $TunnelName } | Out-Null
            $oldCreds = Join-Path $cloudflaredDir "$existing.json"
            if (Test-Path $oldCreds) {
                Write-Host "  removing local credentials $oldCreds"
                Remove-Item $oldCreds
            }
        } else {
            Write-Host "  remote tunnel '$TunnelName' not found, skipping"
        }
    }

    Write-Host ''
}

# ----- login -----
if (-not (Test-Path (Join-Path $cloudflaredDir 'cert.pem'))) {
    Write-Host '== cert.pem missing, opening browser for login ==' -ForegroundColor Cyan
    $code = Invoke-NativeQuiet { cloudflared tunnel login }
    if ($code -ne 0) { throw 'cloudflared tunnel login failed' }
}

# ----- create / reuse tunnel -----
$uuid = Get-TunnelUuid $TunnelName
if ($uuid) {
    Write-Host "== Tunnel '$TunnelName' exists (UUID: $uuid), reusing ==" -ForegroundColor Yellow
} else {
    Write-Host "== Creating tunnel '$TunnelName' ==" -ForegroundColor Cyan
    $code = Invoke-NativeQuiet { cloudflared tunnel create $TunnelName }
    if ($code -ne 0) { throw "cloudflared tunnel create failed" }
    $uuid = Get-TunnelUuid $TunnelName
    if (-not $uuid) { throw "Tunnel '$TunnelName' still not found after create" }
}

$credsFile = Join-Path $cloudflaredDir "$uuid.json"
if (-not (Test-Path $credsFile)) {
    throw "Credentials file missing: $credsFile (tunnel create may have failed)"
}

# ----- DNS routes (Cloudflare API) -----
# Every hostname is its own zone apex (no ccwu.cc parent zone). `cloudflared tunnel
# route dns` mis-routes to the wrong zone in this topology, so drive the CF API
# directly: upsert a proxied CNAME at each zone's apex -> <uuid>.cfargotunnel.com.
$cfToken = $env:CLOUDFLARE_API_TOKEN
if (-not $cfToken) {
    throw 'CLOUDFLARE_API_TOKEN env var not set. Create a token with Zone.Zone:Read + Zone.DNS:Edit.'
}
$cfHeaders = @{ Authorization = "Bearer $cfToken" }
$cfApi = 'https://api.cloudflare.com/client/v4'

# Single wrapper so every CF call surfaces its error JSON instead of a generic 4xx.
function Invoke-Cf {
    param([string]$Uri, [string]$Method = 'Get', [string]$Body)
    $params = @{ Uri = $Uri; Headers = $cfHeaders; TimeoutSec = 15; Method = $Method }
    if ($Body) { $params.Body = $Body }
    try {
        $resp = Invoke-RestMethod @params
    } catch {
        $msg = $_.ErrorDetails.Message
        if (-not $msg) { $msg = $_.Exception.Message }
        throw "Cloudflare API $Method $Uri failed: $msg"
    }
    if (-not $resp.success) {
        throw "Cloudflare API $Method $Uri returned errors: $($resp.errors | ConvertTo-Json -Compress)"
    }
    return $resp
}

function Get-CfZones {
    $zones = @()
    $page = 1
    do {
        $resp = Invoke-Cf -Uri "$cfApi/zones?per_page=50&page=$page"
        $zones += @($resp.result)
        $page++
    } while ($resp.result_info.total_pages -ge $page)
    return $zones
}

# Longest-suffix zone match: exact zone name, else deepest parent zone.
function Find-CfZone([string]$hostname, [object[]]$zones) {
    $best = $null
    foreach ($z in $zones) {
        if ($hostname -eq $z.name -or $hostname -like "*.$($z.name)") {
            if (-not $best -or $z.name.Length -gt $best.name.Length) { $best = $z }
        }
    }
    return $best
}

# Upsert a proxied CNAME in a zone. Returns 'skip' | 'update' | 'create'.
function Set-CfCname([object]$zone, [string]$hostname, [string]$target) {
    $zid = $zone.id
    $esc = [uri]::EscapeDataString($hostname)
    $list = Invoke-Cf -Uri "$cfApi/zones/$zid/dns_records?type=CNAME&name=$esc"
    $body = @{ type = 'CNAME'; name = $hostname; content = $target; proxied = $true; ttl = 1 } | ConvertTo-Json
    if ($list.result.Count -gt 0) {
        $rec = $list.result[0]
        if ($rec.content -eq $target -and $rec.proxied) { return 'skip' }
        Invoke-Cf -Method Put -Uri "$cfApi/zones/$zid/dns_records/$($rec.id)" -Body $body | Out-Null
        return 'update'
    }
    Invoke-Cf -Method Post -Uri "$cfApi/zones/$zid/dns_records" -Body $body | Out-Null
    return 'create'
}

Write-Host '== Configuring DNS routes ==' -ForegroundColor Cyan
$zones = Get-CfZones
$target = "$uuid.cfargotunnel.com"
$dnsMissing  = @()  # no A record at all
$dnsNotProxy = @()  # has A records but not Cloudflare anycast (not proxied / not pointing to tunnel)
$tlsFail     = @()  # DNS is fine but CF edge has no SSL cert yet (separate sub-zone, Universal SSL pending)
foreach ($hostname in $Routes.Keys) {
    Write-Host "  -> $hostname"

    $zone = Find-CfZone $hostname $zones
    if (-not $zone) {
        Write-Warning "No Cloudflare zone matches $hostname — skipping DNS for it."
        continue
    }

    $action = Set-CfCname $zone $hostname $target
    switch ($action) {
        'create' { Write-Host "    created CNAME $hostname -> $target (proxied)" }
        'update' { Write-Host "    updated CNAME $hostname -> $target (proxied)" }
        'skip'   { Write-Host "    CNAME already correct ($hostname -> $target)" }
    }

    Start-Sleep -Seconds 2
    try {
        $resp = Invoke-RestMethod -Uri "https://1.1.1.1/dns-query?name=$hostname&type=A" `
            -Headers @{ 'accept' = 'application/dns-json' } -TimeoutSec 5
        if (-not $resp.Answer) {
            $dnsMissing += $hostname
        } else {
            # Cloudflare anycast IPs for proxied records are 104.16.0.0/13 and 172.64.0.0/13.
            $cfHit = $false
            foreach ($a in $resp.Answer) {
                if ($a.data -match '^(104\.(1[6-9]|2[0-9]|3[01])\.|172\.(6[4-9]|7[0-9])\.)' ) {
                    $cfHit = $true; break
                }
            }
            if (-not $cfHit) {
                $dnsNotProxy += $hostname
            } elseif (-not (Test-EdgeTls $hostname)) {
                # DNS resolves to CF anycast but the TLS handshake fails -> the
                # edge cert for this hostname is not live yet.
                $tlsFail += $hostname
            }
        }
    } catch {
        Write-Warning "DoH verify failed for ${hostname}: $($_.Exception.Message)"
    }
}

if ($dnsMissing.Count + $dnsNotProxy.Count + $tlsFail.Count -gt 0) {
    Write-Warning ''
    Write-Warning '=== DNS verification problems ==='
}

if ($dnsMissing.Count -gt 0) {
    Write-Warning ''
    Write-Warning 'API wrote the CNAME but DoH still returns no A record (propagation/cache lag):'
    $dnsMissing | ForEach-Object { Write-Warning "    $_" }
    Write-Warning 'Usually clears in a few minutes. Re-check with:'
    Write-Warning "    Invoke-RestMethod 'https://1.1.1.1/dns-query?name=<host>&type=A' -Headers @{accept='application/dns-json'}"
    Write-Warning 'If it persists, confirm the record in the zone: Type=CNAME'
    Write-Warning "    Name=<subdomain>  Target=$uuid.cfargotunnel.com  Proxied (orange cloud)"
}

if ($dnsNotProxy.Count -gt 0) {
    Write-Warning ''
    Write-Warning 'Records exist but are NOT Cloudflare-proxied (will not reach the tunnel):'
    $dnsNotProxy | ForEach-Object { Write-Warning "    $_" }
    Write-Warning 'Fix: dashboard -> the zone -> DNS -> Records -> click the cloud icon'
    Write-Warning '     to switch from "DNS only" (gray) to "Proxied" (orange).'
    Write-Warning '     Or delete + re-add as CNAME pointing to ' + "$uuid.cfargotunnel.com"
}

if ($tlsFail.Count -gt 0) {
    Write-Warning ''
    Write-Warning 'DNS is correct but the Cloudflare edge cannot complete a TLS handshake:'
    $tlsFail | ForEach-Object { Write-Warning "    $_" }
    Write-Warning 'Symptom: browser shows ERR_EMPTY_RESPONSE (connection opens, zero bytes back).'
    Write-Warning 'Cause: this hostname is in its OWN Cloudflare zone whose Universal SSL'
    Write-Warning '       certificate has not been issued/deployed yet (the tunnel itself is fine).'
    Write-Warning 'Fix (recommended): delete that separate zone and instead add the record'
    Write-Warning "       in the parent zone (e.g. ccwu.cc), reusing its already-live cert."
    Write-Warning '     Or: dashboard -> that zone -> SSL/TLS -> Edge Certificates -> wait for'
    Write-Warning '       Universal SSL to go Active (minutes to ~24h), or toggle it to retrigger.'
}

# ----- write config.yml -----
if ((Test-Path $ConfigPath) -and -not $Force) {
    throw "$ConfigPath already exists. Pass -Force to overwrite, or -Cleanup to back up."
}

Write-Host "== Writing $ConfigPath ==" -ForegroundColor Cyan

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
$lines += '  # Catch-all must be last and must exist'
$lines += '  - service: http_status:404'
$lines += ''

Set-Content -Path $ConfigPath -Value $lines -Encoding UTF8

# ----- install service / next steps -----
Write-Host ''
if ($InstallService) {
    if (-not (Test-IsAdmin)) {
        throw 'Administrator PowerShell required for service install. Reopen as admin.'
    }
    Write-Host '== Installing Windows service (manual mode) ==' -ForegroundColor Cyan
    # `cloudflared service install` is unreliable on Windows: it sometimes registers
    # the service with bare `cloudflared.exe` (no args) and never copies config to
    # the SYSTEM profile. Do it ourselves.

    $sysDir = 'C:\Windows\System32\config\systemprofile\.cloudflared'
    if (-not (Test-Path $sysDir)) { New-Item -ItemType Directory -Path $sysDir | Out-Null }

    # Copy config + cert + creds JSON into SYSTEM profile so the service (running
    # as LocalSystem) can read them.
    Copy-Item $ConfigPath (Join-Path $sysDir 'config.yml') -Force
    $certSrc = Join-Path $cloudflaredDir 'cert.pem'
    if (Test-Path $certSrc) { Copy-Item $certSrc (Join-Path $sysDir 'cert.pem') -Force }
    Copy-Item $credsFile (Join-Path $sysDir "$uuid.json") -Force

    # Rewrite credentials-file path inside the SYSTEM copy of config.yml so the
    # service finds the JSON in its own profile.
    $sysConfig = Join-Path $sysDir 'config.yml'
    $sysCreds  = (Join-Path $sysDir "$uuid.json") -replace '\\', '/'
    (Get-Content $sysConfig) `
        -replace '^credentials-file:.*', "credentials-file: `"$sysCreds`"" `
        | Set-Content $sysConfig -Encoding UTF8

    # Log to disk so a crash leaves a trace. --loglevel/--logfile are global flags
    # and must precede the `tunnel run` subcommand.
    $logDir = 'C:\ProgramData\cloudflared'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
    $logFile = Join-Path $logDir 'cloudflared.log'

    # Use sc.exe to create the service with explicit binPath (note the space after `=`).
    $cloudflaredExe = (Get-Command cloudflared).Source
    $binPath = "`"$cloudflaredExe`" --config `"$sysConfig`" --loglevel info --logfile `"$logFile`" tunnel run $TunnelName"
    Write-Host "  binPath: $binPath"
    sc.exe create cloudflared binPath= "$binPath" start= auto DisplayName= 'Cloudflared Tunnel' | Out-Host
    sc.exe description cloudflared "cloudflared tunnel run $TunnelName (managed by create_cloudflared_tunnel.ps1)" | Out-Host

    # Auto-heal on crash: restart after 5s, reset the failure counter daily so the
    # 3-action ladder applies per-day rather than being exhausted permanently.
    sc.exe failure cloudflared reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Host

    Start-Service cloudflared
    Start-Sleep -Seconds 4
    Invoke-NativeQuiet { cloudflared tunnel info $TunnelName } | Out-Null
} else {
    Write-Host 'Done. Next, pick one:' -ForegroundColor Green
    Write-Host "  Foreground:  cloudflared --config `"$ConfigPath`" tunnel run $TunnelName"
    Write-Host "  As service:  rerun this script as Administrator with -InstallService"
    Write-Host "  Or manually: cloudflared --config `"$ConfigPath`" service install"
}
