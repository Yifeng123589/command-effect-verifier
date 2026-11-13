# CEV M1 · Run acceptance against Extract-CevFacts.ps1
# Usage: powershell -File Run-Acceptance.ps1
# Preview package · does not execute the subject command

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

$extractor = Join-Path $Root 'Extract-CevFacts.ps1'
if (-not (Test-Path -LiteralPath $extractor)) { throw "missing $extractor" }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

Write-Host "Root=$Root"
Write-Host "Extractor=$extractor"

$cases = Get-Content -LiteralPath $CasesPath -Raw -Encoding UTF8 | ConvertFrom-Json
$results = @()
$pass = 0
$fail = 0

function Assert-Field {
    param($Actual, $Expected, $Key, [System.Collections.ArrayList]$Errors)
    if ($null -eq $Expected.PSObject.Properties[$Key]) { return }
    $exp = $Expected.$Key
    $act = $Actual.$Key
    if ($exp -is [bool] -or $act -is [bool]) {
        if ([bool]$act -ne [bool]$exp) {
            [void]$Errors.Add("$Key expected=$exp actual=$act")
        }
        return
    }
    if ("$act" -ne "$exp") {
        [void]$Errors.Add("$Key expected=$exp actual=$act")
    }
}

foreach ($case in $cases) {
    $errors = New-Object System.Collections.ArrayList
    $env:CEV_M1_COMMAND = $case.command
    $rawOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $extractor -CommandFromEnv 2>&1 | Out-String
    Remove-Item Env:CEV_M1_COMMAND -ErrorAction SilentlyContinue
    $rawOut = $rawOut.Trim()
    $facts = $null
    try {
        $facts = $rawOut | ConvertFrom-Json
    } catch {
        [void]$errors.Add("json_parse_failed: $($_.Exception.Message) raw=$rawOut")
    }

    $outFile = Join-Path $OutDir ($case.id + '.json')
    if ($facts) {
        $facts | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $outFile -Encoding UTF8
        foreach ($prop in $case.expect.PSObject.Properties) {
            Assert-Field -Actual $facts -Expected $case.expect -Key $prop.Name -Errors $errors
        }
        if ($case.PSObject.Properties['expect_path_contains'] -and $case.expect_path_contains) {
            $paths = @($facts.paths)
            $hit = $false
            foreach ($p in $paths) {
                if ("$p" -like ("*" + $case.expect_path_contains + "*")) { $hit = $true }
            }
            if (-not $hit) { [void]$errors.Add("path_missing_fragment=$($case.expect_path_contains) paths=$($paths -join ',')") }
        }
        if ($case.PSObject.Properties['expect_var_level'] -and $case.expect_var_level) {
            $levels = @($facts.var_resolution | ForEach-Object { $_.level })
            if ($levels -notcontains $case.expect_var_level) {
                [void]$errors.Add("var_level_missing=$($case.expect_var_level) got=$($levels -join ',')")
            }
        }
        if ($case.PSObject.Properties['expect_sink_contains'] -and $case.expect_sink_contains) {
            $sk = @($facts.dynamic_sinks)
            if ($sk -notcontains $case.expect_sink_contains) {
                [void]$errors.Add("sink_missing=$($case.expect_sink_contains) got=$($sk -join ',')")
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
    }
    $mark = if ($ok) { 'PASS' } else { 'FAIL' }
    Write-Host ("[{0}] {1}" -f $mark, $case.id)
    if (-not $ok) {
        foreach ($e in $errors) { Write-Host ("    - " + $e) }
    }
}

$summary = [ordered]@{
    timestamp_asia_shanghai = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' CST'
    total                   = $cases.Count
    pass                    = $pass
    fail                    = $fail
    acceptance_gate         = ($fail -eq 0)
    results                 = $results
}
$summaryPath = Join-Path $OutDir 'acceptance_summary.json'
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
Write-Host ("--- total={0} pass={1} fail={2} gate={3}" -f $cases.Count, $pass, $fail, ($fail -eq 0))
Write-Host ("summary: " + $summaryPath)
if ($fail -gt 0) { exit 1 } else { exit 0 }


