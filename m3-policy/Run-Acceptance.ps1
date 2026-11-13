# CEV M3 · Run acceptance against Apply-CevPolicy.ps1
# Usage: powershell -NoProfile -File Run-Acceptance.ps1
# Preview package · gate-only · does not execute the subject command

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

$applier = Join-Path $Root 'Apply-CevPolicy.ps1'
if (-not (Test-Path -LiteralPath $applier)) { throw "missing $applier" }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

Write-Host "Root=$Root"
Write-Host "Applier=$applier"

$cases = Get-Content -LiteralPath $CasesPath -Raw -Encoding UTF8 | ConvertFrom-Json
$results = @()
$pass = 0
$fail = 0

$requiredIds = @('E3_mirror_fetch','E4_delete_system','E5_unknown_domain','E7_replay_residue','P1_precheck_source_missing','P3_m2_bounce_passthrough')

foreach ($case in $cases) {
    $errors = New-Object System.Collections.ArrayList
    $verdictPath = $case.verdict
    if (-not [System.IO.Path]::IsPathRooted($verdictPath)) {
        $verdictPath = Join-Path $Root ($verdictPath -replace '/', '\')
    }
    $verdictPath = [System.IO.Path]::GetFullPath($verdictPath)

    if (-not (Test-Path -LiteralPath $verdictPath)) {
        [void]$errors.Add("verdict_missing=$verdictPath")
    }

    $policyDir = Join-Path $Root 'policy'
    $tmpCorrupt = $null
    if ($case.PSObject.Properties['corrupt_policy'] -and $case.corrupt_policy) {
        $tmpCorrupt = Join-Path $OutDir ('_corrupt_policy_' + $case.id)
        if (Test-Path -LiteralPath $tmpCorrupt) { Remove-Item -LiteralPath $tmpCorrupt -Recurse -Force }
        New-Item -ItemType Directory -Path $tmpCorrupt | Out-Null
        # write broken JSON
        '{ this is not valid json [[[' | Set-Content -LiteralPath (Join-Path $tmpCorrupt 'regions.json') -Encoding UTF8
        '{ "matrix": ' | Set-Content -LiteralPath (Join-Path $tmpCorrupt 'matrix.json') -Encoding UTF8
        $policyDir = $tmpCorrupt
    }

    $verdictObj = $null
    $rawOut = $null
    if ($errors.Count -eq 0) {
        $rawOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $applier `
            -VerdictFile $verdictPath `
            -PolicyDir $policyDir `
            -Pretty 2>&1 | Out-String
        $rawOut = $rawOut.Trim()
        try {
            $verdictObj = $rawOut | ConvertFrom-Json
        } catch {
            [void]$errors.Add("json_parse_failed: $($_.Exception.Message) raw=$rawOut")
        }
    }

    if ($tmpCorrupt -and (Test-Path -LiteralPath $tmpCorrupt)) {
        Remove-Item -LiteralPath $tmpCorrupt -Recurse -Force -ErrorAction SilentlyContinue
    }

    $outFile = Join-Path $OutDir ($case.id + '.json')
    if ($verdictObj) {
        $verdictObj | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $outFile -Encoding UTF8
        $expVerdict = $case.expect.verdict
        if ("$($verdictObj.verdict)" -ne "$expVerdict") {
            [void]$errors.Add("verdict expected=$expVerdict actual=$($verdictObj.verdict)")
        }
        if ($case.PSObject.Properties['expect_rule_substr'] -and $case.expect_rule_substr) {
            $rules = @()
            if ($verdictObj.matched_rules) { $rules = @($verdictObj.matched_rules | ForEach-Object { [string]$_ }) }
            $joined = ($rules -join ' | ')
            if ($joined -notlike ("*" + $case.expect_rule_substr + "*")) {
                [void]$errors.Add("rule_substr_missing=$($case.expect_rule_substr) got=$joined")
            }
        }
        if ($case.PSObject.Properties['expect_notice_code'] -and $case.expect_notice_code) {
            $ncodes = @()
            if ($verdictObj.notices) { $ncodes = @($verdictObj.notices | ForEach-Object { $_.code }) }
            if ($ncodes -notcontains $case.expect_notice_code) {
                [void]$errors.Add("notice_code_missing=$($case.expect_notice_code) got=$($ncodes -join ',')")
            }
        }
        # P3 hard: bounce must stay bounce (no upgrade)
        if ($case.id -eq 'P3_m2_bounce_passthrough' -and $verdictObj.verdict -eq 'pass') {
            [void]$errors.Add('P3_bounce_upgraded_to_pass_forbidden')
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

$reqOk = $true
foreach ($rid in $requiredIds) {
    $hit = $results | Where-Object { $_.id -eq $rid -and $_.pass }
    if (-not $hit) { $reqOk = $false }
}

$gate = ($fail -eq 0) -and ($cases.Count -ge 10) -and $reqOk

$summary = [ordered]@{
    timestamp_asia_shanghai = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' CST'
    total                   = $cases.Count
    pass                    = $pass
    fail                    = $fail
    acceptance_gate         = $gate
    includes_e3_e7_p1_p3    = $reqOk
    required_ids            = $requiredIds
    results                 = $results
}
$summaryPath = Join-Path $OutDir 'acceptance_summary.json'
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
Write-Host ("--- total={0} pass={1} fail={2} gate={3} required={4}" -f $cases.Count, $pass, $fail, $gate, $reqOk)
Write-Host ("summary: " + $summaryPath)
if (-not $gate) { exit 1 } else { exit 0 }
