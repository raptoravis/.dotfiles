# Isolate the ego lite function: never execute the complete bootstrap or a real installer.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ScriptPath = Join-Path $PSScriptRoot '..\..\..\install-windows.ps1'
$Tokens = $null
$ParseErrors = $null
$Ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path $ScriptPath), [ref]$Tokens, [ref]$ParseErrors)
if ($ParseErrors.Count) { throw ($ParseErrors | Out-String) }
$Function = $Ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Install-EgoLite'
}, $true)
if (-not $Function) { throw 'Install-EgoLite function missing' }

foreach ($Case in @('ready', 'runtime-failed', 'skill-failed', 'onboarding', 'onboarding-registered', 'install', 'download-failed', 'bad-signature', 'installer-failed')) {
    & {
        $Calls = [Collections.Generic.List[string]]::new()
        $script:LASTEXITCODE = 0
        function Write-Step ($msg) { }
        function Write-Warn2 ($msg) { $Calls.Add("warning: $msg") }
        function Write-Host ($msg) { $Calls.Add("message: $msg") }
        function Test-Cmd ($name) { return $Case -in @('ready', 'runtime-failed', 'skill-failed') }
        function ego-browser {
            $Calls.Add("cli: $args")
            $script:LASTEXITCODE = if (($Case -eq 'runtime-failed' -and $args[0] -eq 'nodejs') -or
                ($Case -eq 'skill-failed' -and $args[0] -eq 'skill')) { 1 } else { 0 }
        }
        function Get-ItemProperty {
            if ($Case -eq 'onboarding') { [pscustomobject]@{ DisplayName = 'ego lite' } }
            elseif ($Case -eq 'onboarding-registered') { [pscustomobject]@{ DisplayName = 'ego (lite)' } }
            else { [pscustomobject]@{ Unrelated = 'registry entry without a display name' } }
        }
        function Invoke-WebRequest {
            $Calls.Add('download')
            if ($Case -eq 'download-failed') { throw 'network unavailable' }
        }
        function Get-AuthenticodeSignature {
            [pscustomobject]@{ Status = $(if ($Case -eq 'bad-signature') { 'NotSigned' } else { 'Valid' }) }
        }
        function Start-Process {
            $Calls.Add('installer')
            [pscustomobject]@{ ExitCode = $(if ($Case -eq 'installer-failed') { 1 } else { 0 }) }
        }
        function Remove-Item { $Calls.Add('cleanup') }
        Invoke-Expression $Function.Extent.Text
        Install-EgoLite
        $Expected = switch ($Case) {
            'ready' { @('cli: nodejs', 'cli: skill') }
            'runtime-failed' { @('cli: nodejs', 'warning:   ego-browser runtime check failed') }
            'skill-failed' { @('cli: nodejs', 'cli: skill', 'warning:   ego-browser skill failed') }
            'onboarding' { @('message:   ego lite is installed.') }
            'onboarding-registered' { @('message:   ego lite is installed.') }
            'install' { @('download', 'installer', 'cleanup') }
            'download-failed' { @('download', 'warning:   ego lite installation failed:', 'cleanup') }
            'bad-signature' { @('download', 'warning:   ego lite installation failed:', 'cleanup') }
            'installer-failed' { @('download', 'installer', 'warning:   ego lite installation failed:', 'cleanup') }
        }
        foreach ($Entry in $Expected) {
            if (-not ($Calls | Where-Object { $_.StartsWith($Entry) })) {
                throw "${Case}: missing '$Entry' in $($Calls -join '; ')"
            }
        }
        if ($Case -notin @('install', 'installer-failed') -and $Calls.Contains('installer')) {
            throw "${Case}: unexpectedly launched installer"
        }
        if ($Case -in @('ready', 'runtime-failed', 'skill-failed', 'onboarding', 'onboarding-registered') -and $Calls.Contains('download')) {
            throw "${Case}: unexpectedly downloaded installer"
        }
        if ($Case -eq 'runtime-failed' -and ($Calls | Where-Object { $_ -eq 'cli: skill' })) {
            throw 'skill should not run after a failed runtime check'
        }
    }
    Write-Output "PASS: $Case"
}
