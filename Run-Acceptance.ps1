# Run-Acceptance.ps1 — run M1, then M2, then M3 acceptance
# Preview package · does NOT execute subject commands
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File Run-Acceptance.ps1

[CmdletBinding()]
param(
    [string]$PackageRoot
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrEmpty($PackageRoot)) {
    if (-not [string]::IsNullOrEmpty($PSScriptRoot)) { $PackageRoot = $PSScriptRoot }
    elseif ($MyInvocation.MyCommand.Path) { $PackageRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
    else { throw 'Could not resolve package root; pass -PackageRoot explicitly.' }
}

$steps = @(
    @{ Name = 'M1 facts';      Script = 'm1-facts\Run-Acceptance.ps1' },
    @{ Name = 'M2 claims';     Script = 'm2-claims\Run-Acceptance.ps1' },
    @{ Name = 'M3 policy';     Script = 'm3-policy\Run-Acceptance.ps1' }
)

foreach ($step in $steps) {
    $path = Join-Path $PackageRoot $step.Script
    if (-not (Test-Path -LiteralPath $path)) { throw "missing $path" }
    Write-Host ("======== {0} ========" -f $step.Name)
    & powershell -NoProfile -ExecutionPolicy Bypass -File $path
    if ($LASTEXITCODE -ne 0) {
        throw ("{0} acceptance failed with exit {1}" -f $step.Name, $LASTEXITCODE)
    }
}

Write-Host "All three acceptance suites passed."
exit 0
