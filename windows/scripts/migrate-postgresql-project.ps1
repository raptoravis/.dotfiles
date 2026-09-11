# Copy one PostgreSQL database into this host and create an isolated app role.
# Source credentials are read from an existing env file. Generated target
# credentials are written only to the requested, gitignored env file and to a
# per-user DPAPI file under LocalAppData.

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SourceEnvFile,
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z_][a-z0-9_]*$')]
    [string]$TargetDatabase,
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z_][a-z0-9_]*$')]
    [string]$TargetUser,
    [Parameter(Mandatory)]
    [string]$TargetEnvFile,
    [int]$Port = 5432
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function New-RandomPassword {
    $bytes = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    [Convert]::ToBase64String($bytes).TrimEnd('=') + '!aA1'
}

function ConvertTo-PlainText([Security.SecureString]$SecureValue) {
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function ConvertTo-UrlEncoded([string]$Value) {
    [Uri]::EscapeDataString($Value)
}

$sourceLine = Get-Content -LiteralPath $SourceEnvFile |
    Where-Object { $_ -match '^\s*DATABASE_URL\s*=' } |
    Select-Object -Last 1
if (-not $sourceLine) { throw "DATABASE_URL was not found in $SourceEnvFile." }
$sourceUrl = ($sourceLine -split '=', 2)[1].Trim()
$sourceUrl = $sourceUrl -replace '^postgresql\+[^:]+:', 'postgresql:'
$sourceUri = [Uri]$sourceUrl
$sourceUserInfo = $sourceUri.UserInfo -split ':', 2
$sourceUser = [Uri]::UnescapeDataString($sourceUserInfo[0])
$sourcePassword = if ($sourceUserInfo.Count -gt 1) { [Uri]::UnescapeDataString($sourceUserInfo[1]) } else { '' }
$sourceDatabase = $sourceUri.AbsolutePath.TrimStart('/')

$pgBin = Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin' -Directory -ErrorAction SilentlyContinue |
    Sort-Object { [int]$_.Parent.Name } -Descending |
    Select-Object -First 1
if (-not $pgBin) { throw 'PostgreSQL client tools were not found under C:\Program Files\PostgreSQL.' }
$pgDump = Join-Path $pgBin.FullName 'pg_dump.exe'
$pgRestore = Join-Path $pgBin.FullName 'pg_restore.exe'
$psql = Join-Path $pgBin.FullName 'psql.exe'

$superCredentialPath = Join-Path $env:LOCALAPPDATA 'dotfiles\postgresql\superuser-password.xml'
if (-not (Test-Path -LiteralPath $superCredentialPath)) {
    throw "Local PostgreSQL credential is missing. Run setup-postgresql.ps1 first."
}
$superPassword = ConvertTo-PlainText (Import-Clixml -LiteralPath $superCredentialPath)
$appPassword = New-RandomPassword
$dumpPath = Join-Path $env:TEMP ("postgres-migration-{0}.dump" -f [Guid]::NewGuid().ToString('N'))

try {
    Write-Host "Dumping $($sourceUri.Host)/$sourceDatabase..." -ForegroundColor Cyan
    $env:PGPASSWORD = $sourcePassword
    & $pgDump -h $sourceUri.Host -p $sourceUri.Port -U $sourceUser -d $sourceDatabase `
        --format=custom --no-owner --no-privileges --file=$dumpPath
    if ($LASTEXITCODE -ne 0) { throw "pg_dump failed (exit $LASTEXITCODE)." }

    $env:PGPASSWORD = $superPassword
    $roleExists = & $psql -h localhost -p $Port -U postgres -d postgres -tAc `
        "SELECT 1 FROM pg_roles WHERE rolname = '$TargetUser'"
    $escapedAppPassword = $appPassword.Replace("'", "''")
    if ($roleExists -ne '1') {
        "CREATE ROLE `"$TargetUser`" LOGIN PASSWORD '$escapedAppPassword';" |
            & $psql -h localhost -p $Port -U postgres -d postgres -v ON_ERROR_STOP=1
        if ($LASTEXITCODE -ne 0) { throw 'Failed to create the target role.' }
    } else {
        "ALTER ROLE `"$TargetUser`" WITH LOGIN PASSWORD '$escapedAppPassword';" |
            & $psql -h localhost -p $Port -U postgres -d postgres -v ON_ERROR_STOP=1
        if ($LASTEXITCODE -ne 0) { throw 'Failed to rotate the target role password.' }
    }

    $databaseExists = & $psql -h localhost -p $Port -U postgres -d postgres -tAc `
        "SELECT 1 FROM pg_database WHERE datname = '$TargetDatabase'"
    if ($databaseExists -eq '1') {
        throw "Target database '$TargetDatabase' already exists; refusing to overwrite it."
    }
    & $psql -h localhost -p $Port -U postgres -d postgres -v ON_ERROR_STOP=1 `
        -c "CREATE DATABASE `"$TargetDatabase`" OWNER `"$TargetUser`""
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create the target database.' }

    Write-Host "Restoring into local database $TargetDatabase..." -ForegroundColor Cyan
    & $pgRestore -h localhost -p $Port -U postgres -d $TargetDatabase `
        --no-owner --no-privileges --role=$TargetUser --exit-on-error $dumpPath
    if ($LASTEXITCODE -ne 0) { throw "pg_restore failed (exit $LASTEXITCODE)." }

    $tailscaleCommand = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    $tailscaleExe = if ($tailscaleCommand) {
        $tailscaleCommand.Source
    } else {
        Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
    }
    $tailscaleStatus = if (Test-Path -LiteralPath $tailscaleExe) {
        & $tailscaleExe status --json 2>$null | ConvertFrom-Json
    }
    if (-not $tailscaleStatus -or -not $tailscaleStatus.Self.Online) {
        throw 'Tailscale is not connected. Run tailscale up, then rerun this migration.'
    }
    $tailscaleHost = $tailscaleStatus.Self.DNSName.TrimEnd('.')
    if (-not $tailscaleHost) { $tailscaleHost = $tailscaleStatus.Self.TailscaleIPs[0] }
    $encodedPassword = ConvertTo-UrlEncoded $appPassword
    $targetUrl = "postgresql+asyncpg://${TargetUser}:${encodedPassword}@${tailscaleHost}:$Port/$TargetDatabase"
    $targetLines = @(Get-Content -LiteralPath $TargetEnvFile -ErrorAction SilentlyContinue)
    $updated = $false
    for ($index = 0; $index -lt $targetLines.Count; $index++) {
        if ($targetLines[$index] -match '^\s*DATABASE_URL\s*=') {
            $targetLines[$index] = "DATABASE_URL=$targetUrl"
            $updated = $true
        }
    }
    if (-not $updated) { $targetLines += "DATABASE_URL=$targetUrl" }
    Set-Content -LiteralPath $TargetEnvFile -Value $targetLines -Encoding UTF8

    $appCredentialDir = Join-Path $env:LOCALAPPDATA 'dotfiles\postgresql\apps'
    New-Item -ItemType Directory -Force -Path $appCredentialDir | Out-Null
    ConvertTo-SecureString $appPassword -AsPlainText -Force |
        Export-Clixml -LiteralPath (Join-Path $appCredentialDir "$TargetDatabase.xml") -Force
    Write-Host "Migration complete. Updated $TargetEnvFile." -ForegroundColor Green
} finally {
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    $sourcePassword = $null
    $superPassword = $null
    $appPassword = $null
    if (Test-Path -LiteralPath $dumpPath) { Remove-Item -LiteralPath $dumpPath -Force }
}
