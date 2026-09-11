# Install and configure a reusable PostgreSQL server on this Windows host.
#
# Run from PowerShell. The script elevates itself when needed, installs
# PostgreSQL as an auto-starting Windows service, and permits TCP access only
# from Tailscale's address range. The generated superuser password is stored
# for the current Windows user with DPAPI; it is never written to this repo.

[CmdletBinding()]
param(
    [ValidateSet('16', '17', '18')]
    [string]$Version = '18',
    [ValidateRange(1, 65535)]
    [int]$Port = 5432
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function New-RandomPassword {
    $bytes = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    [Convert]::ToBase64String($bytes).TrimEnd('=') + '!aA1'
}

if (-not (Test-Admin)) {
    $logPath = Join-Path $env:TEMP 'dotfiles-setup-postgresql.log'
    Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
    $escapedScript = $PSCommandPath.Replace("'", "''")
    $escapedLog = $logPath.Replace("'", "''")
    $command = @"
`$ErrorActionPreference = 'Stop'
try {
    & '$escapedScript' -Version '$Version' -Port $Port *>&1 | Out-File -LiteralPath '$escapedLog' -Encoding utf8
    exit 0
} catch {
    `$_ | Out-String | Out-File -LiteralPath '$escapedLog' -Encoding utf8 -Append
    exit 1
}
"@
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    Write-Host 'Administrator access is required; opening an elevated PowerShell window.' -ForegroundColor Cyan
    $process = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList '-NoProfile', '-EncodedCommand', $encodedCommand
    if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath }
    exit $process.ExitCode
}

if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
    throw 'winget is required. Install Microsoft App Installer, then rerun this script.'
}

$credentialDir = Join-Path $env:LOCALAPPDATA 'dotfiles\postgresql'
$credentialPath = Join-Path $credentialDir 'superuser-password.xml'
$packageId = "PostgreSQL.PostgreSQL.$Version"
$serviceName = "postgresql-x64-$Version"
$service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

if (-not $service) {
    New-Item -ItemType Directory -Force -Path $credentialDir | Out-Null
    $plainPassword = New-RandomPassword
    try {
        $securePassword = ConvertTo-SecureString $plainPassword -AsPlainText -Force
        $securePassword | Export-Clixml -LiteralPath $credentialPath -Force

        Write-Host "Installing PostgreSQL $Version as Windows service $serviceName..." -ForegroundColor Cyan
        $installerArgs = @(
            'install', '--id', $packageId, '--exact', '--source', 'winget',
            '--accept-package-agreements', '--accept-source-agreements',
            '--override',
            "--mode unattended --unattendedmodeui none --superpassword `"$plainPassword`" --serverport $Port --servicename `"$serviceName`""
        )
        & winget.exe @installerArgs
        if ($LASTEXITCODE -ne 0) {
            throw "winget failed to install $packageId (exit $LASTEXITCODE)."
        }
    } finally {
        $plainPassword = $null
    }
    $service = Get-Service -Name $serviceName -ErrorAction Stop
} else {
    Write-Host "$serviceName is already installed." -ForegroundColor DarkGray
}

$serviceConfig = Get-CimInstance Win32_Service -Filter "Name='$serviceName'"
if (-not $serviceConfig.PathName -or $serviceConfig.PathName -notmatch '-D\s+"([^"]+)"') {
    throw "Could not determine the PostgreSQL data directory from service $serviceName."
}
$dataDir = $Matches[1]
$postgresqlConf = Join-Path $dataDir 'postgresql.conf'
$pgHbaConf = Join-Path $dataDir 'pg_hba.conf'

$config = Get-Content -Raw -LiteralPath $postgresqlConf
if ($config -match '(?m)^\s*#?\s*listen_addresses\s*=.*$') {
    $config = $config -replace '(?m)^\s*#?\s*listen_addresses\s*=.*$', "listen_addresses = '*'"
} else {
    $config += "`r`nlisten_addresses = '*'`r`n"
}
if ($config -match '(?m)^\s*#?\s*port\s*=.*$') {
    $config = $config -replace '(?m)^\s*#?\s*port\s*=.*$', "port = $Port"
}
$utf8NoBom = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($postgresqlConf, $config, $utf8NoBom)

$hba = Get-Content -Raw -LiteralPath $pgHbaConf
$hbaMarker = '# dotfiles: Tailscale clients'
if (-not $hba.Contains($hbaMarker)) {
    Add-Content -LiteralPath $pgHbaConf -Encoding UTF8 -Value @"

$hbaMarker
host    all    all    100.64.0.0/10     scram-sha-256
host    all    all    fd7a:115c:a1e0::/48    scram-sha-256
"@
}

$firewallName = "PostgreSQL $Port from Tailscale"
if (-not (Get-NetFirewallRule -DisplayName $firewallName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $firewallName -Direction Inbound -Action Allow `
        -Protocol TCP -LocalPort $Port -RemoteAddress '100.64.0.0/10', 'fd7a:115c:a1e0::/48' `
        -Profile Any | Out-Null
}

Set-Service -Name $serviceName -StartupType Automatic
Restart-Service -Name $serviceName
$service = Get-Service -Name $serviceName
if ($service.Status -ne 'Running') {
    throw "$serviceName did not reach the Running state."
}

Write-Host "PostgreSQL is running on port $Port." -ForegroundColor Green
Write-Host "DPAPI-protected superuser credential: $credentialPath" -ForegroundColor DarkGray
$tailscaleCommand = Get-Command tailscale.exe -ErrorAction SilentlyContinue
$tailscaleExe = if ($tailscaleCommand) {
    $tailscaleCommand.Source
} else {
    Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
}
if (Test-Path -LiteralPath $tailscaleExe) {
    $tailscaleIp = (& $tailscaleExe ip -4 2>$null | Select-Object -First 1)
    if ($tailscaleIp) {
        Write-Host "Tailscale endpoint: ${tailscaleIp}:$Port" -ForegroundColor Green
    } else {
        Write-Warning 'Tailscale is installed but not connected. Run: tailscale up'
    }
} else {
    Write-Warning 'Tailscale is not installed yet. Run install-windows.ps1 first.'
}
