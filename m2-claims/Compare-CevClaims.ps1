# CEV M2 · Compare-CevClaims — declare vs M1 facts → pass|bounce
# Preview package · compare-only (does not execute the subject command)
# Usage:
#   powershell -NoProfile -File Compare-CevClaims.ps1 -ClaimsFile samples\claims\C1_match_delete.claim.json -FactsFile ..\m1-facts\out\A1_alias_del_recurse.json -Pretty

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ClaimsFile,

    [Parameter(Mandatory = $true)]
    [string]$FactsFile,

    [switch]$Pretty
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$script:ValidActions = @('read', 'copy_in', 'copy_out', 'write', 'delete', 'fetch', 'build', 'execute')

function Normalize-PathKey {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $p = $Path.Trim().TrimEnd('\', '/')
    # Prefer GetFullPath when rooted; fall back to literal (case-insensitive compare later)
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
    # loose: strip scheme-ish prefix
    $s = $Url -replace '^[a-zA-Z][a-zA-Z0-9+.-]*://', ''
    $s = ($s -split '[/\\?\s]')[0]
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    return $s.ToLowerInvariant()
}

function New-Mismatch {
    param([string]$Code, [string]$Field, $Expected, $Actual, [string]$Detail = '')
    return [ordered]@{
        code     = $Code
        field    = $Field
        expected = $Expected
        actual   = $Actual
        detail   = $Detail
    }
}

function New-Notice {
    param([string]$Code, [string]$Detail)
    return [ordered]@{
        code   = $Code
        detail = $Detail
    }
}

# --- load inputs ---
if (-not (Test-Path -LiteralPath $ClaimsFile)) { throw "ClaimsFile not found: $ClaimsFile" }
if (-not (Test-Path -LiteralPath $FactsFile)) { throw "FactsFile not found: $FactsFile" }

$claimDoc = Get-Content -LiteralPath $ClaimsFile -Raw -Encoding UTF8 | ConvertFrom-Json
$facts = Get-Content -LiteralPath $FactsFile -Raw -Encoding UTF8 | ConvertFrom-Json

$intent = $null
if ($null -ne $claimDoc.PSObject.Properties['intent']) { $intent = $claimDoc.intent }

$claims = $null
if ($null -ne $claimDoc.PSObject.Properties['claims']) {
    $claims = $claimDoc.claims
} else {
    # allow flat claim file where root IS claims
    $claims = $claimDoc
}

$mismatches = New-Object System.Collections.ArrayList
$notices = New-Object System.Collections.ArrayList
$notes = New-Object System.Collections.ArrayList

# ignore preconditions (M3)
if ($null -ne $claims.PSObject.Properties['preconditions'] -and $null -ne $claims.preconditions) {
    [void]$notes.Add('preconditions_ignored_m2')
}

$schemaOk = $true

# --- schema: claims object ---
if ($null -eq $claims) {
    $schemaOk = $false
    [void]$mismatches.Add((New-Mismatch -Code 'SCHEMA_INVALID' -Field 'claims' -Expected 'object' -Actual $null -Detail 'missing claims'))
}

$action = $null
if ($schemaOk) {
    if ($null -eq $claims.PSObject.Properties['action'] -or $null -eq $claims.action -or [string]::IsNullOrWhiteSpace([string]$claims.action)) {
        $schemaOk = $false
        [void]$mismatches.Add((New-Mismatch -Code 'SCHEMA_INVALID' -Field 'action' -Expected ($script:ValidActions -join '|') -Actual $null -Detail 'missing action'))
    } else {
        $action = [string]$claims.action
        if ($script:ValidActions -notcontains $action) {
            $schemaOk = $false
            [void]$mismatches.Add((New-Mismatch -Code 'SCHEMA_INVALID' -Field 'action' -Expected ($script:ValidActions -join '|') -Actual $action -Detail 'action not in closed enum'))
        }
    }
}

# dest vs paths conflict
$claimPaths = @()
$hasPaths = $false
$hasDest = $false
if ($schemaOk) {
    if ($null -ne $claims.PSObject.Properties['paths'] -and $null -ne $claims.paths) {
        $hasPaths = $true
        $claimPaths = @($claims.paths | ForEach-Object { [string]$_ })
    }
    if ($null -ne $claims.PSObject.Properties['dest'] -and $null -ne $claims.dest -and -not [string]::IsNullOrWhiteSpace([string]$claims.dest)) {
        $hasDest = $true
        $destStr = [string]$claims.dest
        if ($hasPaths) {
            $normDest = Normalize-PathKey $destStr
            $normClaim = @($claimPaths | ForEach-Object { Normalize-PathKey $_ } | Where-Object { $_ })
            if ($normClaim.Count -eq 0 -or ($normClaim -notcontains $normDest)) {
                # both given and conflict → schema bounce
                if ($claimPaths.Count -ne 1 -or ((Normalize-PathKey $claimPaths[0]) -ne $normDest)) {
                    $schemaOk = $false
                    [void]$mismatches.Add((New-Mismatch -Code 'SCHEMA_INVALID' -Field 'dest' -Expected $claimPaths -Actual $destStr -Detail 'dest and paths conflict'))
                }
            }
        } else {
            $claimPaths = @($destStr)
        }
    }
}

# --- hard flags from facts (mechanical bounce) ---
if ($schemaOk) {
    $parseOk = $true
    if ($null -ne $facts.PSObject.Properties['parse_ok']) { $parseOk = [bool]$facts.parse_ok }
    if (-not $parseOk) {
        [void]$mismatches.Add((New-Mismatch -Code 'PARSE_OK_FALSE' -Field 'parse_ok' -Expected $true -Actual $false -Detail 'facts.parse_ok=false'))
    }
    $unresolvable = $false
    if ($null -ne $facts.PSObject.Properties['unresolvable']) { $unresolvable = [bool]$facts.unresolvable }
    if ($unresolvable) {
        [void]$mismatches.Add((New-Mismatch -Code 'UNRESOLVABLE' -Field 'unresolvable' -Expected $false -Actual $true -Detail 'facts.unresolvable=true'))
    }
    $dyn = $false
    if ($null -ne $facts.PSObject.Properties['dynamic_invocation']) { $dyn = [bool]$facts.dynamic_invocation }
    if ($dyn) {
        [void]$mismatches.Add((New-Mismatch -Code 'DYNAMIC_INVOCATION' -Field 'dynamic_invocation' -Expected $false -Actual $true -Detail 'facts.dynamic_invocation=true'))
    }
}

# --- field compare (only when schema ok; hard flags still add mismatches above) ---
if ($schemaOk) {
    # action ↔ action_coarse
    $factsAction = $null
    if ($null -ne $facts.PSObject.Properties['action_coarse']) { $factsAction = $facts.action_coarse }
    if ("$action" -ne "$factsAction") {
        [void]$mismatches.Add((New-Mismatch -Code 'ACTION_MISMATCH' -Field 'action' -Expected $action -Actual $factsAction))
    }

    # recurse
    $claimRecurse = $false
    if ($null -ne $claims.PSObject.Properties['recurse'] -and $null -ne $claims.recurse) {
        $claimRecurse = [bool]$claims.recurse
    }
    $factsRecurse = $false
    if ($null -ne $facts.PSObject.Properties['recurse'] -and $null -ne $facts.recurse) {
        $factsRecurse = [bool]$facts.recurse
    }
    if ($claimRecurse -ne $factsRecurse) {
        [void]$mismatches.Add((New-Mismatch -Code 'RECURSE_MISMATCH' -Field 'recurse' -Expected $claimRecurse -Actual $factsRecurse))
    }

    # paths / dest ↔ paths
    $factsPaths = @()
    if ($null -ne $facts.PSObject.Properties['paths'] -and $null -ne $facts.paths) {
        $factsPaths = @($facts.paths | ForEach-Object { [string]$_ })
    }
    $normClaimPaths = @($claimPaths | ForEach-Object { Normalize-PathKey $_ } | Where-Object { $_ } | Sort-Object -Unique)
    $normFactsPaths = @($factsPaths | ForEach-Object { Normalize-PathKey $_ } | Where-Object { $_ } | Sort-Object -Unique)

    $pathMismatch = $false
    if ($normClaimPaths.Count -eq 0 -and $normFactsPaths.Count -eq 0) {
        # both empty: ok for path dimension (e.g. dynamic cases already bounced)
    } elseif ($hasDest -and -not $hasPaths -and $normClaimPaths.Count -eq 1) {
        # dest-only: single path ∈ facts.paths (or equal set of one)
        if ($normFactsPaths -notcontains $normClaimPaths[0]) {
            $pathMismatch = $true
        }
    } else {
        if ($normClaimPaths.Count -ne $normFactsPaths.Count) {
            $pathMismatch = $true
        } else {
            for ($i = 0; $i -lt $normClaimPaths.Count; $i++) {
                if ($normClaimPaths[$i] -ne $normFactsPaths[$i]) { $pathMismatch = $true; break }
            }
        }
    }
    if ($pathMismatch) {
        [void]$mismatches.Add((New-Mismatch -Code 'PATH_MISMATCH' -Field 'paths' -Expected $claimPaths -Actual $factsPaths -Detail 'normalized case-insensitive inequality'))
    }

    # url: loose notice only
    $claimUrl = $null
    if ($null -ne $claims.PSObject.Properties['url'] -and $null -ne $claims.url -and -not [string]::IsNullOrWhiteSpace([string]$claims.url)) {
        $claimUrl = [string]$claims.url
    }
    $factsUrl = $null
    if ($null -ne $facts.PSObject.Properties['url'] -and $null -ne $facts.url -and -not [string]::IsNullOrWhiteSpace([string]$facts.url)) {
        $factsUrl = [string]$facts.url
    }
    $ch = Get-UrlHost $claimUrl
    $fh = Get-UrlHost $factsUrl
    if ($ch -or $fh) {
        if ($ch -ne $fh) {
            [void]$notices.Add((New-Notice -Code 'URL_HOST_DIVERGENCE' -Detail ("claim_host=$ch facts_host=$fh")))
        }
    }
    # intent domain cross-check (loose notice)
    if ($intent -and $ch) {
        $intentLower = [string]$intent
        if ($intentLower -notmatch [regex]::Escape($ch)) {
            # also try bare domain without www
            $bare = $ch -replace '^www\.', ''
            if ($intentLower -notmatch [regex]::Escape($bare)) {
                [void]$notices.Add((New-Notice -Code 'URL_INTENT_DOMAIN_CROSS' -Detail ("intent may not mention host=$ch")))
            }
        }
    }
}

$verdict = if ($mismatches.Count -eq 0) { 'pass' } else { 'bounce' }

$result = [ordered]@{
    verdict   = $verdict
    intent    = $intent
    claims    = $claims
    facts_ref = [System.IO.Path]::GetFileName($FactsFile)
    mismatches = @($mismatches)
    notices   = @($notices)
    notes     = @($notes)
}

$json = $result | ConvertTo-Json -Depth 10
if ($Pretty) {
    Write-Output $json
} else {
    # compact-ish still fine via ConvertTo-Json
    Write-Output $json
}
