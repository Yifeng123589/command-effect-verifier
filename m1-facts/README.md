# M1 — Fact extractor

Extract mechanical facts from a single PowerShell command string. This module
does **not** execute the subject command and does not decide allow/bounce.

See `docs/DESIGN.md` §4.1–4.5.

## Capabilities

| Piece | Source |
|-------|--------|
| AST | `[Parser]::ParseInput` |
| Var tiering | L1 constant / L2 whitelist (`$HOME`, `$env:*`, …) / L3 unresolvable |
| Alias | CommandInfo → `del` / `rd` / `ri` → `Remove-Item` |
| Dynamic sinks | `iex`, `& $cmd`, call operator, `[scriptblock]::Create`, `Add-Type`, alias→iex |
| Blast radius | `-Recurse`, `-Force`, wildcard, `-Include` |

## Single command

```powershell
powershell -NoProfile -File Extract-CevFacts.ps1 -Command "del C:\temp\x -Recurse" -Pretty
```

Commands containing `$()` / nested quotes — use env to avoid cmdline reparse:

```powershell
$env:CEV_M1_COMMAND = 'Remove-Item "$(Join-Path $HOME ''x'')"'
powershell -NoProfile -File Extract-CevFacts.ps1 -CommandFromEnv -Pretty
```

Or `-CommandFile path.txt`.

## Acceptance

```powershell
powershell -NoProfile -File Run-Acceptance.ps1
```

Writes `out/<case_id>.json` and `out/acceptance_summary.json`. Sample commands
use `C:\Users\Example\...` example paths, not a real user profile.
