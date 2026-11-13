# CEV M3 · Apply-CevPolicy — M2 verdict → precheck → region×action matrix → pass|bounce|human|block
# Preview package · gate-only (does not execute the subject command)
# Pipeline: M2 bounce passthrough → precheck → replay residue → matrix
# Usage:
#   powershell -NoProfile -File Apply-CevPolicy.ps1 -VerdictFile samples\verdicts\E4_delete_system.verdict.json -Pretty

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VerdictFile,

    [string]$FactsFile,

    [string]$PolicyDir,

    [string]$M1Root,

    [switch]$Pretty
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

if (-not [string]::IsNullOrEmpty($PSScriptRoot)) {
    $script:Root = $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    $script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    throw 'Could not resolve module root; run this script as a file so $PSScriptRoot is set.'
}

if ([string]::IsNullOrEmpty($PolicyDir)) {
    $PolicyDir = Join-Path $script:Root 'policy'
}
if ([string]::IsNullOrEmpty($M1Root)) {
    $M1Root = Join-Path (Split-Path -Parent $script:Root) 'm1-facts'
}


function Get-CevAnchorPaths {
    $fixtureRoot = [System.IO.Path]::GetFullPath((Join-Path $script:Root 'fixtures\root'))
    $moduleRoot = [System.IO.Path]::GetFullPath($script:Root)
    return @{ FixtureRoot = $fixtureRoot; ModuleRoot = $moduleRoot }
}

function Expand-CevText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $a = Get-CevAnchorPaths
    $t = $Text.Replace('${CEV_FIXTURE_ROOT}', [string]$a.FixtureRoot)
    $t = $t.Replace('${CEV_MODULE_ROOT}', [string]$a.ModuleRoot)
    return $t
}

function Expand-CevPathsInObject {
    param($Obj, [string[]]$Keys)
    if ($null -eq $Obj) { return }
    foreach ($k in $Keys) {
        if ($null -eq $Obj.PSObject.Properties[$k]) { continue }
        $v = $Obj.$k
        if ($null -eq $v) { continue }
        if ($v -is [string]) {
            $Obj.$k = Expand-CevText $v
        } elseif ($v -is [System.Array] -or ($v -is [System.Collections.IEnumerable] -and $v -isnot [string])) {
            $new = @()
            foreach ($item in @($v)) {
                if ($null -eq $item) { $new += $item } else { $new += Expand-CevText ([string]$item) }
            }
            $Obj.$k = $new
        }
    }
}

function Normalize-PathKey {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $p = $Path.Trim()
    # strip \\?\ prefix for matching
    if ($p.StartsWith('\\?\')) { $p = $p.Substring(4) }
    $p = $p.TrimEnd('\', '/')
    try {
        if ([System.IO.Path]::IsPathRooted($p)) {
            $full = [System.IO.Path]::GetFullPath($p)
            return $full.TrimEnd('\', '/').ToLowerInvariant()
        }
    } catch { }
    return $p.ToLowerInvariant()
}

function Get-UrlHost {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
    try {
        $u = [Uri]$Url
        if ($u.IsAbsoluteUri) { return $u.Host.ToLowerInvariant() }
    } catch { }
    $s = $Url -replace '^[a-zA-Z][a-zA-Z0-9+.-]*://', ''
    $s = ($s -split '[/\\?\s]')[0]
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    return $s.ToLowerInvariant()
}

function Test-PathPattern {
    param([string]$NormPath, [string]$Pattern)
    if ([string]::IsNullOrWhiteSpace($NormPath) -or [string]::IsNullOrWhiteSpace($Pattern)) { return $false }
    $pat = $Pattern.Trim().TrimEnd('\', '/').ToLowerInvariant()
    # wildcard * → regex
    if ($pat.Contains('*') -or $pat.Contains('?')) {
        $rx = '^' + ([regex]::Escape($pat) -replace '\\\*','.*' -replace '\\\?','.') + '$'
        return [regex]::IsMatch($NormPath, $rx)
    }
    # exact or prefix (directory containment)
    if ($NormPath -eq $pat) { return $true }
    if ($NormPath.StartsWith($pat + '\')) { return $true }
    return $false
}

function Resolve-Region {
    param($RegionsDoc, [string]$NormPath)
    if (-not $NormPath) { return $null }
    $best = $null
    $bestPri = -1
    foreach ($r in @($RegionsDoc.regions)) {
        $pri = 0
        if ($null -ne $r.PSObject.Properties['priority']) { $pri = [int]$r.priority }
        foreach ($pat in @($r.patterns)) {
            if (Test-PathPattern -NormPath $NormPath -Pattern ([string]$pat)) {
                if ($pri -ge $bestPri) {
                    $bestPri = $pri
                    $best = [string]$r.name
                }
            }
        }
    }
    return $best
}

function Get-WorseVerdict {
    param([string]$A, [string]$B, $Rank)
    $ra = 0; $rb = 0
    if ($Rank.PSObject.Properties[$A]) { $ra = [int]$Rank.$A }
    if ($Rank.PSObject.Properties[$B]) { $rb = [int]$Rank.$B }
    if ($rb -gt $ra) { return $B } else { return $A }
}

function New-Notice {
    param([string]$Code, [string]$Detail)
    return [ordered]@{ code = $Code; detail = $Detail }
}

function Emit-Result {
    param($Result)
    $json = $Result | ConvertTo-Json -Depth 12
    Write-Output $json
}

# --- load verdict ---
if (-not (Test-Path -LiteralPath $VerdictFile)) { throw "VerdictFile not found: $VerdictFile" }
$verdictDoc = Get-Content -LiteralPath $VerdictFile -Raw -Encoding UTF8 | ConvertFrom-Json

$intent = $null
if ($null -ne $verdictDoc.PSObject.Properties['intent']) { $intent = $verdictDoc.intent }

$claims = $null
if ($null -ne $verdictDoc.PSObject.Properties['claims']) { $claims = $verdictDoc.claims }

$mismatches = @()
if ($null -ne $verdictDoc.PSObject.Properties['mismatches'] -and $verdictDoc.mismatches) {
    $mismatches = @($verdictDoc.mismatches)
}
$notices = New-Object System.Collections.ArrayList
if ($null -ne $verdictDoc.PSObject.Properties['notices'] -and $verdictDoc.notices) {
    foreach ($n in @($verdictDoc.notices)) { [void]$notices.Add($n) }
}
$notes = New-Object System.Collections.ArrayList
if ($null -ne $verdictDoc.PSObject.Properties['notes'] -and $verdictDoc.notes) {
    foreach ($n in @($verdictDoc.notes)) { [void]$notes.Add($n) }
}
$matchedRules = New-Object System.Collections.ArrayList

$factsRef = $null
if ($null -ne $verdictDoc.PSObject.Properties['facts_ref']) { $factsRef = $verdictDoc.facts_ref }

$m2Verdict = $null
if ($null -ne $verdictDoc.PSObject.Properties['verdict']) { $m2Verdict = [string]$verdictDoc.verdict }

# --- M2 bounce passthrough (hard short-circuit) ---
if ($m2Verdict -eq 'bounce') {
    [void]$matchedRules.Add('m2_bounce_passthrough')
    [void]$notes.Add('m3_skipped_precheck_and_matrix')
    $out = [ordered]@{
        verdict         = 'bounce'
        intent          = $intent
        claims          = $claims
        facts_ref       = $factsRef
        mismatches      = $mismatches
        notices         = @($notices)
        matched_rules   = @($matchedRules)
        preconditions   = $(if ($claims -and $claims.PSObject.Properties['preconditions']) { $claims.preconditions } else { $null })
        precheck_ok     = $null
        notes           = @($notes)
    }
    Emit-Result $out
    return
}

# Missing claims → fail-closed human
if ($null -eq $claims) {
    [void]$matchedRules.Add('fail_closed_missing_claims')
    $out = [ordered]@{
        verdict         = 'human'
        intent          = $intent
        claims          = $null
        facts_ref       = $factsRef
        mismatches      = $mismatches
        notices         = @($notices)
        matched_rules   = @($matchedRules)
        preconditions   = $null
        precheck_ok     = $false
        notes           = @('fail_closed_missing_claims')
    }
    Emit-Result $out
    return
}

# --- load policy (fail-closed → human) ---
$regionsPath = Join-Path $PolicyDir 'regions.json'
$matrixPath = Join-Path $PolicyDir 'matrix.json'
$regionsDoc = $null
$matrixDoc = $null
$policyOk = $true
$policyErr = $null
try {
    if (-not (Test-Path -LiteralPath $regionsPath)) { throw "missing regions.json" }
    if (-not (Test-Path -LiteralPath $matrixPath)) { throw "missing matrix.json" }
    $regionsDoc = Get-Content -LiteralPath $regionsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $matrixDoc = Get-Content -LiteralPath $matrixPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $regionsDoc -or $null -eq $matrixDoc) { throw "null policy doc" }
    if ($null -eq $matrixDoc.PSObject.Properties['matrix']) { throw "matrix field missing" }
} catch {
    $policyOk = $false
    $policyErr = $_.Exception.Message
}

if (-not $policyOk) {
    $fc = 'human'
    if ($matrixDoc -and $matrixDoc.PSObject.Properties['fail_closed_verdict']) {
        $fc = [string]$matrixDoc.fail_closed_verdict
    }
    [void]$matchedRules.Add("fail_closed_corrupt_policy: $policyErr")
    $out = [ordered]@{
        verdict         = $fc
        intent          = $intent
        claims          = $claims
        facts_ref       = $factsRef
        mismatches      = $mismatches
        notices         = @($notices)
        matched_rules   = @($matchedRules)
        preconditions   = $(if ($claims.PSObject.Properties['preconditions']) { $claims.preconditions } else { $null })
        precheck_ok     = $null
        notes           = @("policy_load_failed: $policyErr")
    }
    Emit-Result $out
    return
}

# Expand portable placeholders in region patterns (package-relative fixtures).
foreach ($r in @($regionsDoc.regions)) {
    if ($null -eq $r.PSObject.Properties['patterns']) { continue }
    $expanded = @()
    foreach ($pat in @($r.patterns)) { $expanded += Expand-CevText ([string]$pat) }
    $r.patterns = $expanded
}

# --- resolve facts ---
$facts = $null
if ($null -ne $verdictDoc.PSObject.Properties['facts'] -and $null -ne $verdictDoc.facts) {
    $facts = $verdictDoc.facts
} elseif (-not [string]::IsNullOrWhiteSpace($FactsFile)) {
    if (-not (Test-Path -LiteralPath $FactsFile)) { throw "FactsFile not found: $FactsFile" }
    $facts = Get-Content -LiteralPath $FactsFile -Raw -Encoding UTF8 | ConvertFrom-Json
} elseif (-not [string]::IsNullOrWhiteSpace($factsRef)) {
    $cand = Join-Path $M1Root "out\$factsRef"
    if (Test-Path -LiteralPath $cand) {
        $facts = Get-Content -LiteralPath $cand -Raw -Encoding UTF8 | ConvertFrom-Json
    } else {
        $cand2 = Join-Path $script:Root "samples\facts\$factsRef"
        if (Test-Path -LiteralPath $cand2) {
            $facts = Get-Content -LiteralPath $cand2 -Raw -Encoding UTF8 | ConvertFrom-Json
        }
    }
}

if ($null -eq $facts) {
    # allow claims-only matrix on claims paths when facts missing → fail-closed human
    [void]$matchedRules.Add('fail_closed_missing_facts')
    $out = [ordered]@{
        verdict         = 'human'
        intent          = $intent
        claims          = $claims
        facts_ref       = $factsRef
        mismatches      = $mismatches
        notices         = @($notices)
        matched_rules   = @($matchedRules)
        preconditions   = $(if ($claims.PSObject.Properties['preconditions']) { $claims.preconditions } else { $null })
        precheck_ok     = $null
        notes           = @('fail_closed_missing_facts')
    }
    Emit-Result $out
    return
}

# Expand portable placeholders in claims/facts paths before precheck and matrix match.
if ($null -ne $claims) { Expand-CevPathsInObject -Obj $claims -Keys @('paths','dest') }
if ($null -ne $facts) { Expand-CevPathsInObject -Obj $facts -Keys @('paths','dest') }

# --- precheck (claims.preconditions) ---
$preconditions = $null
if ($null -ne $claims.PSObject.Properties['preconditions']) { $preconditions = $claims.preconditions }
$precheckOk = $true
$precheckDetail = New-Object System.Collections.ArrayList

if ($null -ne $preconditions) {
    $srcFlag = $null
    if ($null -ne $preconditions.PSObject.Properties['source_exists']) {
        $srcFlag = $preconditions.source_exists
    }
    if ($null -ne $srcFlag -and [bool]$srcFlag -eq $true) {
        $srcPaths = @()
        if ($null -ne $claims.PSObject.Properties['paths'] -and $claims.paths) {
            $srcPaths = @($claims.paths | ForEach-Object { [string]$_ })
        }
        if ($srcPaths.Count -eq 0) {
            $precheckOk = $false
            [void]$precheckDetail.Add('source_exists_declared_but_no_paths')
        } else {
            foreach ($sp in $srcPaths) {
                if (-not (Test-Path -LiteralPath $sp)) {
                    $precheckOk = $false
                    [void]$precheckDetail.Add("source_missing=$sp")
                }
            }
        }
    }

    $destFlag = $null
    if ($null -ne $preconditions.PSObject.Properties['dest_parent_exists']) {
        $destFlag = $preconditions.dest_parent_exists
    }
    if ($null -ne $destFlag -and [bool]$destFlag -eq $true) {
        $destPath = $null
        if ($null -ne $claims.PSObject.Properties['dest'] -and $null -ne $claims.dest -and -not [string]::IsNullOrWhiteSpace([string]$claims.dest)) {
            $destPath = [string]$claims.dest
        } elseif ($null -ne $claims.PSObject.Properties['paths'] -and $claims.paths -and @($claims.paths).Count -gt 0) {
            $destPath = [string]@($claims.paths)[0]
        }
        if ([string]::IsNullOrWhiteSpace($destPath)) {
            $precheckOk = $false
            [void]$precheckDetail.Add('dest_parent_exists_declared_but_no_dest')
        } else {
            $parent = $null
            try { $parent = [System.IO.Path]::GetDirectoryName($destPath) } catch { }
            if ([string]::IsNullOrWhiteSpace($parent) -or -not (Test-Path -LiteralPath $parent)) {
                $precheckOk = $false
                [void]$precheckDetail.Add("dest_parent_missing=$parent")
            }
        }
    }
}

if (-not $precheckOk) {
    [void]$matchedRules.Add('precheck_failed')
    foreach ($d in $precheckDetail) { [void]$notes.Add($d) }
    $out = [ordered]@{
        verdict         = 'bounce'
        intent          = $intent
        claims          = $claims
        facts_ref       = $factsRef
        mismatches      = $mismatches
        notices         = @($notices)
        matched_rules   = @($matchedRules)
        preconditions   = $preconditions
        precheck_ok     = $false
        notes           = @($notes)
    }
    Emit-Result $out
    return
}

# --- replay residue (§6.4 S1 simulated flags) ---
$replay = $false
$residueDeclared = $false
if ($null -ne $verdictDoc.PSObject.Properties['replay'] -and $verdictDoc.replay) {
    $replay = [bool]$verdictDoc.replay
}
if ($null -ne $verdictDoc.PSObject.Properties['prior_residue_declared'] -and $null -ne $verdictDoc.prior_residue_declared) {
    $residueDeclared = [bool]$verdictDoc.prior_residue_declared
}
if ($replay -and -not $residueDeclared) {
    [void]$matchedRules.Add('replay_residue_undeclared')
    [void]$notes.Add('replay=true and prior_residue_declared=false')
    $out = [ordered]@{
        verdict         = 'bounce'
        intent          = $intent
        claims          = $claims
        facts_ref       = $factsRef
        mismatches      = $mismatches
        notices         = @($notices)
        matched_rules   = @($matchedRules)
        preconditions   = $preconditions
        precheck_ok     = $true
        notes           = @($notes)
    }
    Emit-Result $out
    return
}

# --- matrix: region × action ---
$actionRaw = $null
# prefer facts.action_coarse (strategy eats facts)
if ($null -ne $facts.PSObject.Properties['action_coarse'] -and $null -ne $facts.action_coarse) {
    $actionRaw = [string]$facts.action_coarse
} elseif ($null -ne $claims.PSObject.Properties['action']) {
    $actionRaw = [string]$claims.action
}

$actionsMap = $matrixDoc.actions_map
$col = $null
if ($actionRaw -and $actionsMap.PSObject.Properties[$actionRaw]) {
    $col = [string]$actionsMap.$actionRaw
} else {
    $col = $actionRaw
}

$rank = $matrixDoc.verdict_rank
$finalVerdict = [string]$matrixDoc.default_unmatched
if ([string]::IsNullOrWhiteSpace($finalVerdict)) { $finalVerdict = 'pass' }

# fetch / network
if ($col -eq 'fetch') {
    $url = $null
    if ($null -ne $facts.PSObject.Properties['url'] -and $facts.url) { $url = [string]$facts.url }
    elseif ($null -ne $claims.PSObject.Properties['url'] -and $claims.url) { $url = [string]$claims.url }
    $hostName = Get-UrlHost $url
    $known = @()
    $mirrors = @()
    if ($regionsDoc.network) {
        if ($regionsDoc.network.known_hosts) { $known = @($regionsDoc.network.known_hosts | ForEach-Object { $_.ToLowerInvariant() }) }
        if ($regionsDoc.network.mirror_hosts) { $mirrors = @($regionsDoc.network.mirror_hosts | ForEach-Object { $_.ToLowerInvariant() }) }
    }
    if ([string]::IsNullOrWhiteSpace($hostName)) {
        $finalVerdict = [string]$matrixDoc.network.unknown
        [void]$matchedRules.Add('network x fetch(no_host) -> ' + $finalVerdict)
    } elseif ($mirrors -contains $hostName) {
        $finalVerdict = [string]$matrixDoc.network.known_mirror
        [void]$matchedRules.Add("network x known_mirror($hostName) -> $finalVerdict")
        [void]$notices.Add((New-Notice -Code 'MIRROR_URL' -Detail "host=$hostName is known mirror; intent may reference official forge"))
    } elseif ($known -contains $hostName) {
        $finalVerdict = [string]$matrixDoc.network.known_official
        [void]$matchedRules.Add("network x known_official($hostName) -> $finalVerdict")
    } else {
        $finalVerdict = [string]$matrixDoc.network.unknown
        [void]$matchedRules.Add("network x unknown_host($hostName) -> $finalVerdict")
    }
} else {
    # path-based regions
    $factPaths = @()
    if ($null -ne $facts.PSObject.Properties['paths'] -and $facts.paths) {
        $factPaths = @($facts.paths | ForEach-Object { [string]$_ })
    }
    if ($factPaths.Count -eq 0 -and $null -ne $claims.PSObject.Properties['paths'] -and $claims.paths) {
        $factPaths = @($claims.paths | ForEach-Object { [string]$_ })
    }

    $recurse = $false
    if ($null -ne $facts.PSObject.Properties['recurse'] -and $null -ne $facts.recurse) {
        $recurse = [bool]$facts.recurse
    } elseif ($null -ne $claims.PSObject.Properties['recurse'] -and $null -ne $claims.recurse) {
        $recurse = [bool]$claims.recurse
    }

    if ($factPaths.Count -eq 0) {
        # no path → unmatched default
        [void]$matchedRules.Add("no_path_unmatched -> $finalVerdict")
    } else {
        foreach ($fp in $factPaths) {
            $norm = Normalize-PathKey $fp
            $region = Resolve-Region -RegionsDoc $regionsDoc -NormPath $norm
            if (-not $region) {
                [void]$matchedRules.Add("unmatched_path($fp) -> $finalVerdict")
                continue
            }
            $regionMatrix = $null
            if ($matrixDoc.matrix.PSObject.Properties[$region]) {
                $regionMatrix = $matrixDoc.matrix.$region
            }
            $cell = $null
            if ($regionMatrix -and $col -and $regionMatrix.PSObject.Properties[$col]) {
                $cell = [string]$regionMatrix.$col
            } else {
                $cell = [string]$matrixDoc.default_unmatched
            }
            $ruleLabel = "${region} x ${col} -> ${cell}"
            [void]$matchedRules.Add($ruleLabel)
            $finalVerdict = Get-WorseVerdict -A $finalVerdict -B $cell -Rank $rank

            # S1 recurse amplifier: if delete+recurse, also note (real subtree scan not required)
            if ($recurse -and $col -eq 'delete') {
                [void]$notes.Add("recurse_delete_checked_path=$fp region=$region")
            }
        }
    }
}

# block irreversible note
if ($finalVerdict -eq 'block') {
    [void]$notes.Add('block_non_downgradeable')
}

$out = [ordered]@{
    verdict         = $finalVerdict
    intent          = $intent
    claims          = $claims
    facts_ref       = $factsRef
    mismatches      = $mismatches
    notices         = @($notices)
    matched_rules   = @($matchedRules)
    preconditions   = $preconditions
    precheck_ok     = $true
    notes           = @($notes)
}
Emit-Result $out
