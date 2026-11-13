# Run-Chain.ps1 — M1 → M2 → M3 smoke against the package fixture
# Preview package · gate-only · does NOT execute the subject command
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File Run-Chain.ps1

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

$m1 = Join-Path $PackageRoot 'm1-facts\Extract-CevFacts.ps1'
$m2 = Join-Path $PackageRoot 'm2-claims\Compare-CevClaims.ps1'
$m3 = Join-Path $PackageRoot 'm3-policy\Apply-CevPolicy.ps1'
$policyDir = Join-Path $PackageRoot 'm3-policy\policy'
$outDir = Join-Path $PackageRoot 'out'
$fixture = Join-Path $PackageRoot 'm3-policy\fixtures\root\README.txt'

foreach ($p in @($m1, $m2, $m3, $policyDir, $fixture)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "missing $p" }
}
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

$fixtureFull = [System.IO.Path]::GetFullPath($fixture)
$command = "Get-Content -LiteralPath '$fixtureFull'"

$claimsObj = [ordered]@{
    intent = 'Preview chain smoke: read the package fixture README'
    claims = [ordered]@{
        action        = 'read'
        paths         = @($fixtureFull)
        dest          = $null
        url           = $null
        recurse       = $false
        preconditions = [ordered]@{
            source_exists       = $true
            dest_parent_exists  = $null
        }
    }
}
$claimsFile = Join-Path $outDir 'chain_claims.json'
($claimsObj | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $claimsFile -Encoding UTF8

Write-Host "CEV preview Run-Chain · gate-only (subject command is not executed)"
Write-Host "PackageRoot=$PackageRoot"
Write-Host "Command(subject NOT executed)=$command"

# --- M1 ---
$env:CEV_M1_COMMAND = $command
$factsRaw = & powershell -NoProfile -ExecutionPolicy Bypass -File $m1 -CommandFromEnv -Pretty 2>&1 | Out-String
Remove-Item Env:CEV_M1_COMMAND -ErrorAction SilentlyContinue
$factsRaw = $factsRaw.Trim()
$facts = $factsRaw | ConvertFrom-Json
$factsPath = Join-Path $outDir 'chain_m1_facts.json'
$facts | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $factsPath -Encoding UTF8
Write-Host "M1 ok · action_coarse=$($facts.action_coarse) · parse_ok=$($facts.parse_ok) → $factsPath"

# --- M2 ---
$m2Raw = & powershell -NoProfile -ExecutionPolicy Bypass -File $m2 `
    -ClaimsFile $claimsFile `
    -FactsFile $factsPath `
    -Pretty 2>&1 | Out-String
$m2Raw = $m2Raw.Trim()
$m2Verdict = $m2Raw | ConvertFrom-Json
$m2Path = Join-Path $outDir 'chain_m2_verdict.json'
$m2Verdict | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $m2Path -Encoding UTF8
Write-Host "M2 ok · verdict=$($m2Verdict.verdict) → $m2Path"

# --- M3 ---
$m3Raw = & powershell -NoProfile -ExecutionPolicy Bypass -File $m3 `
    -VerdictFile $m2Path `
    -FactsFile $factsPath `
    -PolicyDir $policyDir `
    -Pretty 2>&1 | Out-String
$m3Raw = $m3Raw.Trim()
$m3Verdict = $m3Raw | ConvertFrom-Json
$m3Path = Join-Path $outDir 'chain_m3_verdict.json'
$m3Verdict | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $m3Path -Encoding UTF8
Write-Host "M3 ok · verdict=$($m3Verdict.verdict) → $m3Path"

$summary = [ordered]@{
    timestamp_asia_shanghai = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' Asia/Shanghai'
    stage                   = 'cev-public-preview'
    subject_executed        = $false
    m1_facts                = $factsPath
    m2_verdict              = [string]$m2Verdict.verdict
    m3_verdict              = [string]$m3Verdict.verdict
    chain_pass              = (([string]$m2Verdict.verdict -eq 'pass') -and ([string]$m3Verdict.verdict -eq 'pass'))
}
$summaryPath = Join-Path $outDir 'chain_summary.json'
($summary | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $summaryPath -Encoding UTF8
Write-Host "SUMMARY chain_pass=$($summary.chain_pass) · subject_executed=false → $summaryPath"

if (-not $summary.chain_pass) {
    throw "Run-Chain FAIL · m2=$($m2Verdict.verdict) m3=$($m3Verdict.verdict)"
}
exit 0
