# CEV M2 · Run acceptance against Compare-CevClaims.ps1
# Usage: powershell -NoProfile -File Run-Acceptance.ps1
# Preview package · compare-only · reads ../m1-facts/out/*.json from a prior M1 run

[CmdletBinding()]
param(
    [string]$CasesPath,
    [string]$OutDir,
    [string]$Root
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrEmpty($Root)) {
    if (-not [string]::IsNullOrEmpty($PSScriptRoot)) {
        $Root = $PSScriptRoot
    } elseif ($MyInvocation.MyCommand.Path) {
        $Root = Split-Path -Parent $MyInvocation.MyCommand.Path
    } else {
        throw 'Could not resolve module root; pass -Root explicitly.'
    }
}
if ([string]::IsNullOrEmpty($CasesPath)) {
    $CasesPath = Join-Path $Root 'samples\acceptance_cases.json'
}
if ([string]::IsNullOrEmpty($OutDir)) {
    $OutDir = Join-Path $Root 'out'
}

$comparer = Join-Path $Root 'Compare-CevClaims.ps1'
if (-not (Test-Path -LiteralPath $comparer)) { throw "missing $comparer" }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

Write-Host "Root=$Root"
Write-Host "Comparer=$comparer"

$cases = Get-Content -LiteralPath $CasesPath -Raw -Encoding UTF8 | ConvertFrom-Json
$results = @()
$pass = 0
$fail = 0

foreach ($case in $cases) {
    $errors = New-Object System.Collections.ArrayList
    $claimsPath = $case.claims
    if (-not [System.IO.Path]::IsPathRooted($claimsPath)) {
        $claimsPath = Join-Path $Root ($claimsPath -replace '/', '\')
    }
    $factsPath = $case.facts
    if (-not [System.IO.Path]::IsPathRooted($factsPath)) {
        $factsPath = Join-Path $Root ($factsPath -replace '/', '\')
    }
    $factsPath = [System.IO.Path]::GetFullPath($factsPath)
    $claimsPath = [System.IO.Path]::GetFullPath($claimsPath)

    if (-not (Test-Path -LiteralPath $claimsPath)) {
        [void]$errors.Add("claims_missing=$claimsPath")
    }
    if (-not (Test-Path -LiteralPath $factsPath)) {
        [void]$errors.Add("facts_missing=$factsPath")
    }

    $verdictObj = $null
    $rawOut = $null
    if ($errors.Count -eq 0) {
        $rawOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $comparer -ClaimsFile $claimsPath -FactsFile $factsPath -Pretty 2>&1 | Out-String
        $rawOut = $rawOut.Trim()
        try {
            $verdictObj = $rawOut | ConvertFrom-Json
        } catch {
            [void]$errors.Add("json_parse_failed: $($_.Exception.Message) raw=$rawOut")
        }
    }

    $outFile = Join-Path $OutDir ($case.id + '.json')
    if ($verdictObj) {
        $verdictObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $outFile -Encoding UTF8
        $expVerdict = $case.expect.verdict
        if ("$($verdictObj.verdict)" -ne "$expVerdict") {
            [void]$errors.Add("verdict expected=$expVerdict actual=$($verdictObj.verdict)")
        }
        if ($case.PSObject.Properties['expect_mismatch_code'] -and $case.expect_mismatch_code) {
            $codes = @()
            if ($verdictObj.mismatches) {
                $codes = @($verdictObj.mismatches | ForEach-Object { $_.code })
            }
            if ($codes -notcontains $case.expect_mismatch_code) {
                [void]$errors.Add("mismatch_code_missing=$($case.expect_mismatch_code) got=$($codes -join ',')")
            }
        }
        if ($expVerdict -eq 'pass') {
            $mmCount = 0
            if ($verdictObj.mismatches) { $mmCount = @($verdictObj.mismatches).Count }
            if ($mmCount -ne 0) {
                [void]$errors.Add("pass_but_mismatches=$mmCount")
            }
        }
    }

    $ok = ($errors.Count -eq 0)
    if ($ok) { $pass++ } else { $fail++ }
    $results += [ordered]@{
        id     = $case.id
        pass   = $ok
        errors = @($errors)
        out    = $outFile
        note   = $(if ($case.PSObject.Properties['note']) { $case.note } else { $null })
    }
    $mark = if ($ok) { 'PASS' } else { 'FAIL' }
    Write-Host ("[{0}] {1}" -f $mark, $case.id)
    if (-not $ok) {
        foreach ($e in $errors) { Write-Host ("    - " + $e) }
    }
}

$hasC2 = ($results | Where-Object { $_.id -eq 'C2_path_diverge' -and $_.pass }).Count -gt 0
$hasC3 = ($results | Where-Object { $_.id -eq 'C3_var_path_diverge' -and $_.pass }).Count -gt 0
$gate = ($fail -eq 0) -and ($cases.Count -ge 8) -and $hasC2 -and $hasC3

$summary = [ordered]@{
    timestamp_asia_shanghai = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' CST'
    total                   = $cases.Count
    pass                    = $pass
    fail                    = $fail
    acceptance_gate         = $gate
    includes_e1_e2          = ($hasC2 -and $hasC3)
    results                 = $results
}
$summaryPath = Join-Path $OutDir 'acceptance_summary.json'
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
Write-Host ("--- total={0} pass={1} fail={2} gate={3} e1e2={4}" -f $cases.Count, $pass, $fail, $gate, ($hasC2 -and $hasC3))
Write-Host ("summary: " + $summaryPath)
if (-not $gate) { exit 1 } else { exit 0 }
