# M2 — Claims vs. facts comparer

Read a structured declaration (`intent` + `claims`) and compare it to M1
facts. This module does **not** execute the subject command.

See `docs/DESIGN.md` §3 / §5. Run **M1 acceptance first** so `../m1-facts/out/`
exists; those generated fact files are the comparer inputs.

## Capabilities

| Piece | Notes |
|-------|--------|
| Declaration | `intent` is display-only; illegal `action` enums bounce |
| Field map | `action`↔`action_coarse`; `paths`/`dest`↔`paths`; `recurse`; `url` is loose (notice) |
| Hard marks | `parse_ok=false` / `unresolvable` / `dynamic_invocation` → bounce |
| Ignored here | `preconditions` (handled in M3) |
| Verdicts | `pass` or `bounce`, plus `mismatches` and `notices` |

## Single command

```powershell
powershell -NoProfile -File Compare-CevClaims.ps1 `
  -ClaimsFile samples\claims\C1_match_delete.claim.json `
  -FactsFile ..\m1-facts\out\A1_alias_del_recurse.json `
  -Pretty
```

## Acceptance

```powershell
powershell -NoProfile -File Run-Acceptance.ps1
```

Writes `out/<case_id>.json` and `out/acceptance_summary.json`. The gate expects
at least 8 cases including C2/C3 (path-divergence / E1–E2 class).
