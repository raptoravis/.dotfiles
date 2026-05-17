#Requires -Version 5.1
<#
.SYNOPSIS
    Create / update a cloudflared named tunnel (pure local config mode).
    Builds the tunnel, routes DNS, writes config.yml. Optionally cleans up
    stale state and installs the Windows service.

.PARAMETER Preset
    Preset bundle (TunnelName + Routes). One of: com, home.
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
    [ValidateSet('com', 'home')]
    [string]$Preset = 'com',

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
            'haishan.ccwu.cc' = 'http://localhost:8765'
            'peifeng.ccwu.cc' = 'http://localhost:9280'
            'yunxing.ccwu.cc' = 'http://localhost:6534'
        }
    }
    home = @{
        TunnelName = 'home'
        Routes     = @{
            'tunan.ccwu.cc'   = 'http://localhost:9280'
            'tianyun.ccwu.cc' = 'http://localhost:50876'
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

# ----- DNS routes -----
Write-Host '== Configuring DNS routes ==' -ForegroundColor Cyan
$dnsMissing  = @()  # no A record at all
$dnsNotProxy = @()  # has A records but not Cloudflare anycast (not proxied / not pointing to tunnel)
$dnsZombies  = @()  # cloudflared mis-routed to the wrong zone (creates a literal "x.y.z.wrongzone" record)
foreach ($hostname in $Routes.Keys) {
    Write-Host "  -> $hostname"

    # Capture cloudflared output so we can detect wrong-zone messages like
    # `Added CNAME yunxing.ccwu.cc.haishan.ccwu.cc which will route...`
    # cmd /c merges stderr (where cloudflared writes INF logs) into stdout, so
    # PowerShell never sees the stderr stream and doesn't treat the lines as errors.
    $cfExe = (Get-Command cloudflared).Source
    $routeOut = cmd /c "`"$cfExe`" tunnel route dns $TunnelName $hostname 2>&1" | Out-String
    Write-Host $routeOut.TrimEnd()

    # Detect wrong-zone bug: when the user's CF account has a parent zone (e.g.
    # haishan.ccwu.cc) registered separately, cloudflared may treat the requested
    # hostname as relative and append the zone, producing "<host>.<zone>".
    foreach ($line in ($routeOut -split "`n")) {
        if ($line -match '\b([a-z0-9.-]+)\s+(?:which will route|is already configured)') {
            $reportedHost = $matches[1]
            if ($reportedHost -ne $hostname) {
                $dnsZombies += [pscustomobject]@{
                    Requested = $hostname
                    Created   = $reportedHost
                }
            }
        }
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
            if (-not $cfHit) { $dnsNotProxy += $hostname }
        }
    } catch {
        Write-Warning "DoH verify failed for ${hostname}: $($_.Exception.Message)"
    }
}

if ($dnsMissing.Count + $dnsNotProxy.Count + $dnsZombies.Count -gt 0) {
    Write-Warning ''
    Write-Warning '=== DNS verification problems ==='
}

if ($dnsMissing.Count -gt 0) {
    Write-Warning ''
    Write-Warning 'No DNS record found (cloudflared may have falsely reported "already configured"):'
    $dnsMissing | ForEach-Object { Write-Warning "    $_" }
    Write-Warning 'Fix: dashboard -> the correct zone -> DNS -> Records -> add CNAME:'
    Write-Warning "    Type=CNAME  Name=<subdomain>  Target=$uuid.cfargotunnel.com  Proxy=Proxied (orange cloud)"
}

if ($dnsNotProxy.Count -gt 0) {
    Write-Warning ''
    Write-Warning 'Records exist but are NOT Cloudflare-proxied (will not reach the tunnel):'
    $dnsNotProxy | ForEach-Object { Write-Warning "    $_" }
    Write-Warning 'Fix: dashboard -> the zone -> DNS -> Records -> click the cloud icon'
    Write-Warning '     to switch from "DNS only" (gray) to "Proxied" (orange).'
    Write-Warning '     Or delete + re-add as CNAME pointing to ' + "$uuid.cfargotunnel.com"
}

if ($dnsZombies.Count -gt 0) {
    Write-Warning ''
    Write-Warning 'cloudflared wrote into the WRONG zone, creating zombie records:'
    foreach ($z in $dnsZombies) {
        Write-Warning ("    requested {0,-30} but created {1}" -f $z.Requested, $z.Created)
    }
    Write-Warning 'Cause: your CF account has both `ccwu.cc` and a sub-zone (e.g. `haishan.ccwu.cc`)'
    Write-Warning '       registered as separate zones. cloudflared picks the wrong one.'
    Write-Warning 'Fix:'
    Write-Warning '  1) dashboard -> the WRONG zone -> DNS -> Records -> delete the zombie name'
    Write-Warning '  2) dashboard -> the correct parent zone (e.g. ccwu.cc) -> DNS -> Records'
    Write-Warning "     -> add CNAME  Name=<subdomain>  Target=$uuid.cfargotunnel.com  Proxied"
    Write-Warning '  3) Or remove the sub-zone from your account if you do not need it as a separate zone.'
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

    # Use sc.exe to create the service with explicit binPath (note the space after `=`).
    $cloudflaredExe = (Get-Command cloudflared).Source
    $binPath = "`"$cloudflaredExe`" --config `"$sysConfig`" tunnel run $TunnelName"
    Write-Host "  binPath: $binPath"
    sc.exe create cloudflared binPath= "$binPath" start= auto DisplayName= 'Cloudflared Tunnel' | Out-Host
    sc.exe description cloudflared "cloudflared tunnel run $TunnelName (managed by create_cloudflared_tunnel.ps1)" | Out-Host

    Start-Service cloudflared
    Start-Sleep -Seconds 4
    Invoke-NativeQuiet { cloudflared tunnel info $TunnelName } | Out-Null
} else {
    Write-Host 'Done. Next, pick one:' -ForegroundColor Green
    Write-Host "  Foreground:  cloudflared --config `"$ConfigPath`" tunnel run $TunnelName"
    Write-Host "  As service:  rerun this script as Administrator with -InstallService"
    Write-Host "  Or manually: cloudflared --config `"$ConfigPath`" service install"
}
