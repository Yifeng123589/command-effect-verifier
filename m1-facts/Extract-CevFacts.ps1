# CEV M1 · Sandbox Fact Extractor
# Scope: single-command AST + var tiering + alias + dynamic sinks → facts JSON
# Boundary: preview package · extract-only (does not execute the subject command)
# Design: docs/DESIGN.md §4.1–4.5
# Date: 2026-10-16

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command,

    [string]$CommandFile,

    [switch]$CommandFromEnv,

    [switch]$Pretty
)

if ($CommandFromEnv) {
    $Command = $env:CEV_M1_COMMAND
}
elseif (-not [string]::IsNullOrEmpty($CommandFile)) {
    $Command = [System.IO.File]::ReadAllText($CommandFile)
}
if ([string]::IsNullOrEmpty($Command)) {
    throw 'Command is required (pass -Command, -CommandFile, or -CommandFromEnv with env CEV_M1_COMMAND).'
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- closed sets ---
$script:L2Whitelist = @(
    'HOME', 'PWD', 'PSScriptRoot', 'PSCommandPath',
    'MyInvocation', 'Host', 'PID', 'PSVersionTable',
    'true', 'false', 'null'
)

$script:DynamicCmdletNames = @(
    'Invoke-Expression', 'iex',
    'Add-Type',
    'Invoke-Command'   # only flagged when -ScriptBlock from string path; see sink walk
)

$script:ActionMap = @{
    'Remove-Item'       = 'delete'
    'del'               = 'delete'
    'erase'             = 'delete'
    'rd'                = 'delete'
    'rm'                = 'delete'
    'ri'                = 'delete'
    'rmdir'             = 'delete'
    'Copy-Item'         = 'copy_out'   # refined by src/dest later
    'cp'                = 'copy_out'
    'copy'              = 'copy_out'
    'cpi'               = 'copy_out'
    'Move-Item'         = 'write'
    'mi'                = 'write'
    'mv'                = 'write'
    'move'              = 'write'
    'New-Item'          = 'write'
    'ni'                = 'write'
    'Set-Content'       = 'write'
    'sc'                = 'write'
    'Add-Content'       = 'write'
    'ac'                = 'write'
    'Out-File'          = 'write'
    'Get-Content'       = 'read'
    'gc'                = 'read'
    'cat'               = 'read'
    'type'              = 'read'
    'Get-ChildItem'     = 'read'
    'gci'               = 'read'
    'ls'                = 'read'
    'dir'               = 'read'
    'Get-Item'          = 'read'
    'gi'                = 'read'
    'Invoke-WebRequest' = 'fetch'
    'iwr'               = 'fetch'
    'curl'              = 'fetch'
    'wget'              = 'fetch'
    'Invoke-RestMethod' = 'fetch'
    'irm'               = 'fetch'
    'Start-Process'     = 'execute'
    'saps'              = 'execute'
    'start'             = 'execute'
    'Invoke-Expression' = 'execute'
    'iex'               = 'execute'
    'git'               = 'fetch'      # coarse; refined if clone
    'npm'               = 'build'
    'dotnet'            = 'build'
    'msbuild'           = 'build'
}

function New-FactsSkeleton {
    param([string]$Raw)
    [ordered]@{
        command               = $Raw
        parse_ok              = $false
        cmdlet                = $null
        aliases_resolved_from = $null
        action_coarse         = $null
        paths                 = @()
        url                   = $null
        recurse               = $false
        force                 = $false
        has_wildcard          = $false
        include               = @()
        var_resolution        = @()
        dynamic_invocation    = $false
        dynamic_sinks         = @()
        unresolvable          = $false
        notes                 = @()
    }
}

function Test-IsL2VarName {
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return $false }
    if ($Name -like 'env:*') { return $true }
    return $script:L2Whitelist -contains $Name
}

function Resolve-L2Var {
    param([string]$Name)
    try {
        if ($Name -like 'env:*') {
            $envKey = $Name.Substring(4)
            return [Environment]::GetEnvironmentVariable($envKey)
        }
        switch ($Name) {
            'HOME'           { return $HOME }
            'PWD'            { return (Get-Location).Path }
            'PSScriptRoot'   { return $PSScriptRoot }
            'PSCommandPath'  { return $PSCommandPath }
            'PID'            { return $PID }
            'true'           { return $true }
            'false'          { return $false }
            'null'           { return $null }
            default {
                $v = Get-Variable -Name $Name -Scope Global -ErrorAction SilentlyContinue
                if ($null -ne $v) { return $v.Value }
                return $null
            }
        }
    } catch {
        return $null
    }
}

function Classify-Expression {
    <#
    .SYNOPSIS
      Classify an AST expression into L1/L2/L3 and optionally resolve.
    #>
    param(
        $Expr,
        [System.Collections.ArrayList]$VarResolution,
        [System.Collections.ArrayList]$Notes
    )

    if ($null -eq $Expr) {
        return @{ level = 'L1'; value = $null; raw = $null; unresolvable = $false }
    }

    $typeName = $Expr.GetType().Name

    # ConstantExpressionAst — numbers, $true/$false/$null as constants
    if ($typeName -eq 'ConstantExpressionAst') {
        $raw = $Expr.Extent.Text
        return @{ level = 'L1'; value = $Expr.Value; raw = $raw; unresolvable = $false }
    }

    # StringConstantExpressionAst — single-quoted or bare
    if ($typeName -eq 'StringConstantExpressionAst') {
        $raw = $Expr.Extent.Text
        $val = $Expr.Value
        [void]$VarResolution.Add([ordered]@{ raw = $raw; level = 'L1'; value = $val })
        return @{ level = 'L1'; value = $val; raw = $raw; unresolvable = $false }
    }

    # ExpandableStringExpressionAst — "..."
    if ($typeName -eq 'ExpandableStringExpressionAst') {
        $raw = $Expr.Extent.Text
        $nested = @($Expr.NestedExpressions)
        $allL2 = $true
        $hasNested = $nested.Count -gt 0
        foreach ($n in $nested) {
            $nType = $n.GetType().Name
            if ($nType -eq 'VariableExpressionAst') {
                $vname = $n.VariablePath.UserPath
                if (-not (Test-IsL2VarName $vname)) {
                    $allL2 = $false
                    break
                }
            } elseif ($nType -eq 'SubExpressionAst' -or $nType -eq 'ScriptBlockExpressionAst') {
                $allL2 = $false
                break
            } else {
                # Member access etc. inside expandable → L3
                $allL2 = $false
                break
            }
        }
        if (-not $hasNested) {
            # expandable but no nested → treat as L1 literal content
            $val = $Expr.Value
            [void]$VarResolution.Add([ordered]@{ raw = $raw; level = 'L1'; value = $val })
            return @{ level = 'L1'; value = $val; raw = $raw; unresolvable = $false }
        }
        if ($allL2) {
            # resolve by expanding whitelist vars in a constrained way
            try {
                $expanded = $raw
                # strip surrounding quotes for expansion helper
                $inner = $Expr.Value  # PowerShell already partially expands .Value for constants;
                # Prefer manual: replace each variable
                $result = $raw
                if ($result.StartsWith('"') -and $result.EndsWith('"')) {
                    $result = $result.Substring(1, $result.Length - 2)
                }
                foreach ($n in $nested) {
                    if ($n.GetType().Name -eq 'VariableExpressionAst') {
                        $vname = $n.VariablePath.UserPath
                        $vval = Resolve-L2Var $vname
                        if ($null -eq $vval) {
                            [void]$VarResolution.Add([ordered]@{ raw = $raw; level = 'L3'; value = $null })
                            return @{ level = 'L3'; value = $null; raw = $raw; unresolvable = $true }
                        }
                        # replace $Name / ${Name} forms
                        $result = $result -replace [regex]::Escape('$' + $vname), [string]$vval
                        $result = $result -replace [regex]::Escape('${' + $vname + '}'), [string]$vval
                    }
                }
                [void]$VarResolution.Add([ordered]@{ raw = $raw; level = 'L2'; value = $result })
                return @{ level = 'L2'; value = $result; raw = $raw; unresolvable = $false }
            } catch {
                [void]$VarResolution.Add([ordered]@{ raw = $raw; level = 'L3'; value = $null })
                return @{ level = 'L3'; value = $null; raw = $raw; unresolvable = $true }
            }
        }
        [void]$VarResolution.Add([ordered]@{ raw = $raw; level = 'L3'; value = $null })
        return @{ level = 'L3'; value = $null; raw = $raw; unresolvable = $true }
    }

    # VariableExpressionAst alone
    if ($typeName -eq 'VariableExpressionAst') {
        $raw = $Expr.Extent.Text
        $vname = $Expr.VariablePath.UserPath
        if (Test-IsL2VarName $vname) {
            $vval = Resolve-L2Var $vname
            [void]$VarResolution.Add([ordered]@{ raw = $raw; level = 'L2'; value = $vval })
            return @{ level = 'L2'; value = $vval; raw = $raw; unresolvable = ($null -eq $vval) }
        }
        [void]$VarResolution.Add([ordered]@{ raw = $raw; level = 'L3'; value = $null })
        return @{ level = 'L3'; value = $null; raw = $raw; unresolvable = $true }
    }

    # SubExpressionAst $(...) / ScriptBlock → L3
    if ($typeName -eq 'SubExpressionAst' -or $typeName -eq 'ScriptBlockExpressionAst' -or $typeName -eq 'UsingExpressionAst') {
        $raw = $Expr.Extent.Text
        [void]$VarResolution.Add([ordered]@{ raw = $raw; level = 'L3'; value = $null })
        return @{ level = 'L3'; value = $null; raw = $raw; unresolvable = $true }
    }

    # ArrayLiteralAst — resolve elements
    if ($typeName -eq 'ArrayLiteralAst') {
        $raw = $Expr.Extent.Text
        $vals = @()
        $anyL3 = $false
        $anyL2 = $false
        foreach ($el in $Expr.Elements) {
            $c = Classify-Expression -Expr $el -VarResolution $VarResolution -Notes $Notes
            if ($c.unresolvable) { $anyL3 = $true }
            if ($c.level -eq 'L2') { $anyL2 = $true }
            $vals += $c.value
        }
        if ($anyL3) {
            return @{ level = 'L3'; value = $null; raw = $raw; unresolvable = $true }
        }
        $lvl = if ($anyL2) { 'L2' } else { 'L1' }
        return @{ level = $lvl; value = $vals; raw = $raw; unresolvable = $false }
    }

    # MemberExpressionAst / InvokeMemberExpressionAst — usually L3 unless static constant-ish
    if ($typeName -eq 'InvokeMemberExpressionAst') {
        $raw = $Expr.Extent.Text
        # [scriptblock]::Create(...) is a dynamic sink; value unresolvable
        [void]$VarResolution.Add([ordered]@{ raw = $raw; level = 'L3'; value = $null })
        return @{ level = 'L3'; value = $null; raw = $raw; unresolvable = $true }
    }

    if ($typeName -eq 'MemberExpressionAst') {
        $raw = $Expr.Extent.Text
        [void]$VarResolution.Add([ordered]@{ raw = $raw; level = 'L3'; value = $null })
        return @{ level = 'L3'; value = $null; raw = $raw; unresolvable = $true }
    }

    # BinaryExpressionAst — path concat etc. → L3 for safety
    if ($typeName -eq 'BinaryExpressionAst' -or $typeName -eq 'UnaryExpressionAst') {
        $raw = $Expr.Extent.Text
        [void]$VarResolution.Add([ordered]@{ raw = $raw; level = 'L3'; value = $null })
        return @{ level = 'L3'; value = $null; raw = $raw; unresolvable = $true }
    }

    # Paren / Index / other → L3
    $raw = $Expr.Extent.Text
    [void]$VarResolution.Add([ordered]@{ raw = $raw; level = 'L3'; value = $null })
    return @{ level = 'L3'; value = $null; raw = $raw; unresolvable = $true }
}

function Resolve-Alias {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return @{ resolved = $null; from = $null } }
    # strip call operator residue
    $n = $Name.Trim()
    try {
        $cmd = Get-Command -Name $n -ErrorAction SilentlyContinue
        if ($null -eq $cmd) {
            return @{ resolved = $n; from = $null }
        }
        if ($cmd.CommandType -eq 'Alias') {
            $resolved = $cmd.ResolvedCommandName
            if ([string]::IsNullOrEmpty($resolved) -and $null -ne $cmd.ReferencedCommand) {
                $resolved = $cmd.ReferencedCommand.Name
            }
            if ([string]::IsNullOrEmpty($resolved) -and -not [string]::IsNullOrEmpty($cmd.Definition)) {
                $resolved = $cmd.Definition
            }
            if ([string]::IsNullOrEmpty($resolved) -and $null -ne $cmd.ResolvedCommand) {
                $resolved = $cmd.ResolvedCommand.Name
            }
            return @{ resolved = $resolved; from = $n }
        }
        return @{ resolved = $cmd.Name; from = $null }
    } catch {
        return @{ resolved = $n; from = $null }
    }
}

function Get-ActionCoarse {
    param(
        [string]$CmdletName,
        [string]$OriginalName,
        [string[]]$Paths,
        $ParamMap
    )
    $key = $CmdletName
    if ([string]::IsNullOrEmpty($key)) { $key = $OriginalName }
    $lower = $key.ToLowerInvariant()

    # git clone → fetch
    if ($lower -eq 'git') {
        return 'fetch'
    }

    if ($script:ActionMap.ContainsKey($key)) {
        $a = $script:ActionMap[$key]
        # Copy-Item: leave as copy_out coarse; M2+ can refine copy_in/out by zone
        return $a
    }
    if ($script:ActionMap.ContainsKey($OriginalName)) {
        return $script:ActionMap[$OriginalName]
    }
    return 'execute'
}

function Test-HasWildcard {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    return ($Path -match '[\*\?]') -or ($Path -match '\[.+\]')
}

function Find-DynamicSinks {
    param($Ast, [System.Collections.ArrayList]$Sinks)

    # Walk all CommandAst
    $commands = $Ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($c in $commands) {
        $elem0 = $c.CommandElements[0]
        if ($null -eq $elem0) { continue }
        $e0Type = $elem0.GetType().Name

        # variable / expression command name → & $cmd style
        if ($e0Type -eq 'VariableExpressionAst') {
            [void]$Sinks.Add('variable_command_name')
        } elseif ($e0Type -eq 'ScriptBlockExpressionAst') {
            [void]$Sinks.Add('call_operator_scriptblock')
        } elseif ($e0Type -eq 'ExpandableStringExpressionAst' -or $e0Type -eq 'SubExpressionAst') {
            [void]$Sinks.Add('variable_command_name')
        } elseif ($e0Type -eq 'StringConstantExpressionAst' -or $e0Type -eq 'CommandParameterAst') {
            $cname = if ($e0Type -eq 'StringConstantExpressionAst') { $elem0.Value } else { $null }
            if ($cname) {
                $aliasInfo = Resolve-Alias $cname
                $resolved = $aliasInfo.resolved
                $checkNames = @($cname, $resolved) | Where-Object { $_ } | Select-Object -Unique
                foreach ($cn in $checkNames) {
                    if ($cn -eq 'Invoke-Expression' -or $cn -eq 'iex') {
                        [void]$Sinks.Add('invoke_expression')
                    }
                    if ($cn -eq 'Add-Type') {
                        [void]$Sinks.Add('add_type')
                    }
                    # alias that resolves to iex
                    if ($aliasInfo.from -and ($resolved -eq 'Invoke-Expression' -or $resolved -eq 'iex')) {
                        [void]$Sinks.Add('alias_to_iex')
                    }
                }
            }
        }

        # InvocationOperator: . or &
        if ($c.InvocationOperator -eq 'Dot' -or $c.InvocationOperator -eq 'Ampersand') {
            if ($e0Type -eq 'VariableExpressionAst' -or $e0Type -eq 'ScriptBlockExpressionAst') {
                [void]$Sinks.Add('call_operator')
            } elseif ($e0Type -ne 'StringConstantExpressionAst') {
                [void]$Sinks.Add('call_operator')
            }
        }
    }

    # ScriptBlock::Create / [scriptblock]::Create
    $invokes = $Ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)
    foreach ($inv in $invokes) {
        $text = $inv.Extent.Text
        if ($text -match '(?i)scriptblock\s*\]\s*::\s*Create' -or $text -match '(?i)\[scriptblock\]::Create') {
            [void]$Sinks.Add('scriptblock_create')
        }
        # also member name Create on ScriptBlock type
        try {
            $member = $inv.Member
            $memberName = if ($member.Value) { $member.Value } else { $member.Extent.Text }
            if ($memberName -eq 'Create') {
                $exprText = $inv.Expression.Extent.Text
                if ($exprText -match '(?i)scriptblock') {
                    [void]$Sinks.Add('scriptblock_create')
                }
            }
        } catch {}
    }

    # TypeExpression / Add-Type already covered via command name
}

function Extract-CommandFacts {
    param(
        $CmdAst,
        $Facts,
        [System.Collections.ArrayList]$VarResolution,
        [System.Collections.ArrayList]$Notes
    )

    $elements = @($CmdAst.CommandElements)
    if ($elements.Count -eq 0) { return }

    $nameElem = $elements[0]
    $rawName = $null
    $resolvedName = $null
    $aliasFrom = $null

    $nType = $nameElem.GetType().Name
    if ($nType -eq 'StringConstantExpressionAst') {
        $rawName = $nameElem.Value
        $aliasInfo = Resolve-Alias $rawName
        $resolvedName = $aliasInfo.resolved
        $aliasFrom = $aliasInfo.from
    } elseif ($nType -eq 'VariableExpressionAst') {
        $rawName = $nameElem.Extent.Text
        $resolvedName = $null
        [void]$Notes.Add('command_name_is_variable')
    } else {
        $rawName = $nameElem.Extent.Text
        [void]$Notes.Add('command_name_non_literal')
    }

    $Facts.cmdlet = $resolvedName
    if ($aliasFrom) {
        $Facts.aliases_resolved_from = $aliasFrom
    }
# parameter walk
    $paths = New-Object System.Collections.ArrayList
    $includes = New-Object System.Collections.ArrayList
    $positionalArgs = New-Object System.Collections.ArrayList
    $url = $null
    $recurse = $false
    $force = $false
    $i = 1
    while ($i -lt $elements.Count) {
        $el = $elements[$i]
        $elType = $el.GetType().Name

        if ($elType -eq 'CommandParameterAst') {
            $pname = $el.ParameterName
            $arg = $el.Argument
            # switch-like: -Recurse / -Force may have null argument and consume next differently
            # In AST, switches often appear as CommandParameterAst with Argument=null,
            # and the next element is separate.
            $pl = $pname.ToLowerInvariant()

            if ($pl -like 'r*' -and 'recurse'.StartsWith($pl)) {
                $recurse = $true
                # if explicit -$true/-$false argument
                if ($null -ne $arg) {
                    $c = Classify-Expression -Expr $arg -VarResolution $VarResolution -Notes $Notes
                    if ($c.value -eq $false) { $recurse = $false }
                    $i++
                    continue
                }
                $i++
                continue
            }
            if ($pl -like 'fo*' -and 'force'.StartsWith($pl)) {
                $force = $true
                if ($null -ne $arg) {
                    $c = Classify-Expression -Expr $arg -VarResolution $VarResolution -Notes $Notes
                    if ($c.value -eq $false) { $force = $false }
                    $i++
                    continue
                }
                $i++
                continue
            }
            if ($pl -like 'inc*' -and 'include'.StartsWith($pl)) {
                if ($null -ne $arg) {
                    $c = Classify-Expression -Expr $arg -VarResolution $VarResolution -Notes $Notes
                    if ($c.unresolvable) { $Facts.unresolvable = $true }
                    if ($null -ne $c.value) {
                        if ($c.value -is [array]) { foreach ($v in $c.value) { [void]$includes.Add([string]$v) } }
                        else { [void]$includes.Add([string]$c.value) }
                    }
                } elseif (($i + 1) -lt $elements.Count -and $elements[$i+1].GetType().Name -ne 'CommandParameterAst') {
                    $i++
                    $c = Classify-Expression -Expr $elements[$i] -VarResolution $VarResolution -Notes $Notes
                    if ($c.unresolvable) { $Facts.unresolvable = $true }
                    if ($null -ne $c.value) { [void]$includes.Add([string]$c.value) }
                }
                $i++
                continue
            }
            if ($pl -like 'p*' -and ('path'.StartsWith($pl) -or 'literalpath'.StartsWith($pl))) {
                $target = $arg
                if ($null -eq $target -and ($i + 1) -lt $elements.Count) {
                    $i++
                    $target = $elements[$i]
                }
                if ($null -ne $target) {
                    $c = Classify-Expression -Expr $target -VarResolution $VarResolution -Notes $Notes
                    if ($c.unresolvable) { $Facts.unresolvable = $true }
                    if ($null -ne $c.value) {
                        if ($c.value -is [array]) { foreach ($v in $c.value) { [void]$paths.Add([string]$v) } }
                        else { [void]$paths.Add([string]$c.value) }
                    }
                }
                $i++
                continue
            }
            if ($pl -like 'dest*' -or ($pl -like 'd*' -and 'destination'.StartsWith($pl))) {
                $target = $arg
                if ($null -eq $target -and ($i + 1) -lt $elements.Count -and $elements[$i+1].GetType().Name -ne 'CommandParameterAst') {
                    $i++
                    $target = $elements[$i]
                }
                if ($null -ne $target) {
                    $c = Classify-Expression -Expr $target -VarResolution $VarResolution -Notes $Notes
                    if ($c.unresolvable) { $Facts.unresolvable = $true }
                    if ($null -ne $c.value) { [void]$paths.Add([string]$c.value) }
                }
                $i++
                continue
            }
            if ($pl -eq 'uri' -or $pl -eq 'url' -or ($pl -like 'u*' -and 'uri'.StartsWith($pl))) {
                $target = $arg
                if ($null -eq $target -and ($i + 1) -lt $elements.Count -and $elements[$i+1].GetType().Name -ne 'CommandParameterAst') {
                    $i++
                    $target = $elements[$i]
                }
                if ($null -ne $target) {
                    $c = Classify-Expression -Expr $target -VarResolution $VarResolution -Notes $Notes
                    if ($c.unresolvable) { $Facts.unresolvable = $true }
                    if ($null -ne $c.value) { $url = [string]$c.value }
                }
                $i++
                continue
            }
            # generic: skip consuming next if switch; else classify arg for L3 tracking
            if ($null -ne $arg) {
                $c = Classify-Expression -Expr $arg -VarResolution $VarResolution -Notes $Notes
                if ($c.unresolvable) { $Facts.unresolvable = $true }
            } elseif (($i + 1) -lt $elements.Count) {
                $next = $elements[$i + 1]
                if ($next.GetType().Name -ne 'CommandParameterAst') {
                    # might be value for this parameter
                    $i++
                    $c = Classify-Expression -Expr $elements[$i] -VarResolution $VarResolution -Notes $Notes
                    if ($c.unresolvable) { $Facts.unresolvable = $true }
                    # heuristic: path-like positional after unknown named param
                    if ($c.level -ne 'L3' -and $null -ne $c.value -and [string]$c.value -match '[\\/]' ) {
                        [void]$paths.Add([string]$c.value)
                    }
                }
            }
            $i++
            continue
        }

        # positional argument
        $c = Classify-Expression -Expr $el -VarResolution $VarResolution -Notes $Notes
        if ($c.unresolvable) { $Facts.unresolvable = $true }
        if ($null -ne $c.value) {
            $s = [string]$c.value
            [void]$positionalArgs.Add($s)
            # URL heuristic
            if ($s -match '^https?://') {
                $url = $s
            } elseif ($s -match '[\\/]' -or $s -match '^[A-Za-z]:' -or $s -match '^\\\\' -or (Test-HasWildcard $s) -or $s -match '^\.') {
                [void]$paths.Add($s)
            } elseif ($resolvedName -in @('Remove-Item','Copy-Item','Move-Item','Get-ChildItem','Get-Item','Get-Content','Set-Content','New-Item','Out-File')) {
                # path-ish cmdlets: treat positionals as paths
                [void]$paths.Add($s)
            }
        } elseif ($c.raw) {
            [void]$positionalArgs.Add([string]$c.raw)
        }
        $i++
    }

    $Facts.paths = @($paths)
    $Facts.include = @($includes)
    $Facts.url = $url
    $Facts.recurse = [bool]$recurse
    $Facts.force = [bool]$force
    $Facts.has_wildcard = [bool]($Facts.paths | Where-Object { Test-HasWildcard $_ })
    if ($includes.Count -gt 0) { $Facts.has_wildcard = $true }

    $Facts.action_coarse = Get-ActionCoarse -CmdletName $resolvedName -OriginalName $rawName -Paths $Facts.paths -ParamMap $null

    # git: if first positional is clone, still fetch
    if ($rawName -eq 'git' -or $resolvedName -eq 'git') {
        $Facts.action_coarse = 'fetch'
        if ($positionalArgs.Count -gt 1 -and $positionalArgs[0] -eq 'clone') {
            # last non-url arg often dest
            foreach ($pa in $positionalArgs) {
                if ($pa -match '^https?://' -or $pa -match '\.git$') { $Facts.url = $pa }
                elseif ($pa -ne 'clone' -and $pa -notlike '-*') { [void]$paths.Add($pa) }
            }
            $Facts.paths = @($paths | Select-Object -Unique)
        }
    }
}

# ===================== main =====================
$facts = New-FactsSkeleton -Raw $Command
$varResolution = New-Object System.Collections.ArrayList
$notes = New-Object System.Collections.ArrayList
$sinks = New-Object System.Collections.ArrayList

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($Command, [ref]$tokens, [ref]$errors)

if ($errors -and $errors.Count -gt 0) {
    $facts.parse_ok = $false
    $facts.unresolvable = $true
    foreach ($e in $errors) {
        [void]$notes.Add(('parse_error: ' + $e.Message))
    }
    $facts.notes = @($notes)
    $facts.var_resolution = @($varResolution)
    $facts.dynamic_sinks = @()
} else {
    $facts.parse_ok = $true

    Find-DynamicSinks -Ast $ast -Sinks $sinks
    # unique sinks
    $uniqSinks = @($sinks | Select-Object -Unique)
    $facts.dynamic_sinks = $uniqSinks
    $facts.dynamic_invocation = ($uniqSinks.Count -gt 0)

    # primary command: first CommandAst at top / nested
    $cmdAsts = @($ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true))
    if ($cmdAsts.Count -eq 0) {
        [void]$notes.Add('no_command_ast')
        $facts.unresolvable = $true
    } else {
        # For M1 single-command: use first command; if assignment then iex, still extract sinks from whole
        Extract-CommandFacts -CmdAst $cmdAsts[0] -Facts $facts -VarResolution $varResolution -Notes $notes
        # If first is assignment-like only (no real cmdlet), try next
        if (-not $facts.cmdlet -and $cmdAsts.Count -gt 1) {
            Extract-CommandFacts -CmdAst $cmdAsts[1] -Facts $facts -VarResolution $varResolution -Notes $notes
        }
    }

    $facts.var_resolution = @($varResolution)
    $facts.notes = @($notes)
}

# Emit JSON
$json = $facts | ConvertTo-Json -Depth 8 -Compress:(!$Pretty)
# ConvertTo-Json on PS 5.1 may wrap single-element arrays as scalars — normalize via explicit structure
Write-Output $json




