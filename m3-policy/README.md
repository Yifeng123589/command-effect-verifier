# M3 — Policy matrix and precheck

Take an M2-style verdict JSON and apply precheck, replay-residue rules, and
the region × action matrix. This module is **gate-only** and does **not**
execute the subject command.

See `docs/DESIGN.md` §6 / §8 / §6.4 / §10 (E3–E7).

## Capabilities

| Piece | Notes |
|-------|--------|
| Pipeline | M2 bounce is passed through → precheck → replay residue → matrix |
| Precheck | `claims.preconditions.source_exists` / `dest_parent_exists`; failure → bounce |
| Matrix | `policy/regions.json` + `matrix.json` (editable data, not hardcoded) |
| Network | Known official: pass; known mirror: pass + `MIRROR_URL` notice; unknown: human |
| Replay residue | `replay=true` and `prior_residue_declared=false` → bounce |
| Fail-closed | Missing or corrupt policy → `human` (never becomes `pass` on a fault) |
| Verdicts | `pass`, `bounce`, `human`, `block`; `block` must not be downgraded |

### Default matrix (aligned with V1.1 §6.2)

| Region | Read | Write | Delete | Execute |
|--------|------|-------|--------|---------|
| system | pass | human | **block** | **block** |
| user | pass | pass | human | pass |
| backup | pass | pass | human | human |
| project_root | pass | pass | pass | human |
| network | known pass (mirror + notice); unknown human | — | — | — |

### Portable fixtures

`policy/regions.json` and some verdict samples use placeholders:

- `${CEV_FIXTURE_ROOT}` → this module's `fixtures/root` (absolute, at runtime)
- `${CEV_MODULE_ROOT}` → this module directory

`Apply-CevPolicy.ps1` expands them before precheck and path matching. The
sample user region is `C:\Users\Example`. Do not commit production paths.

Known bypasses (documented, not fully blocked in this milestone): 8.3 short
names, trailing dots/spaces, UNC, `\\?\` prefix. Matching is
case-insensitive after normalization.

## Single command

```powershell
powershell -NoProfile -File Apply-CevPolicy.ps1 `
  -VerdictFile samples\verdicts\E4_delete_system.verdict.json `
  -Pretty
```

## Acceptance

```powershell
powershell -NoProfile -File Run-Acceptance.ps1
```

Writes `out/<case_id>.json` and `out/acceptance_summary.json`. The gate expects
at least 10 cases including E3, E4, E5, E7, P1, and P3.
