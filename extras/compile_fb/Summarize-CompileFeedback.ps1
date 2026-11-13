# Summarize-CompileFeedback.ps1
# Thin wrapper around summarize_compile_feedback.py (preview helper; not a gate).
[CmdletBinding()]
param(
    [string]$StageRoot,
    [string]$StderrFile,
    [int]$ExitCode = 2,
    [string]$Toolchain = 'tsc@5',
    [string]$OutJson,
    [string]$OutPrompt
)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrEmpty($StageRoot)) {
    if ($PSScriptRoot) { $StageRoot = $PSScriptRoot }
    else { throw 'Could not resolve script directory; pass -StageRoot explicitly.' }
}
$py = Join-Path $StageRoot 'summarize_compile_feedback.py'
if (-not (Test-Path -LiteralPath $py)) { throw "missing $py" }
$argsList = @($py, '--stage-root', $StageRoot, '--exit-code', $ExitCode, '--toolchain', $Toolchain)
if ($StderrFile) { $argsList += @('--stderr-file', $StderrFile) }
if ($OutJson) { $argsList += @('--out-json', $OutJson) }
if ($OutPrompt) { $argsList += @('--out-prompt', $OutPrompt) }
& python @argsList
exit $LASTEXITCODE
