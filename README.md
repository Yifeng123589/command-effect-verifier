# Command Effect Verifier (CEV) — public preview

A lightweight **local** PowerShell gate: before a command runs, it extracts
mechanical facts, compares them to structured claims from the main model, and
uses a region × action policy matrix to **allow**, **bounce**, or **escalate
to human review**.

- No extra model calls, no tools or skills loaded, no API cost
- Does **not** execute the subject command
- Designed as a PBL (Powered By Limitation) gate component

This folder is a **sanitized preview** for review. It is **not** a published
repository, and copying the files is **not** the same as enabling a gate on
any agent host.

## What's in the box

| Path | Module |
|------|--------|
| `m1-facts/` | Fact extractor (`Extract-CevFacts.ps1`) |
| `m2-claims/` | Claim vs. fact comparer (`Compare-CevClaims.ps1`) |
| `m3-policy/` | Precheck + region × action matrix (`Apply-CevPolicy.ps1`) |
| `docs/DESIGN.md` | V1.1 technical design (lightly cleaned for publication) |
| `Run-Chain.ps1` | M1 → M2 → M3 smoke against the package fixture README |
| `Run-Acceptance.ps1` | Runs the three module acceptance suites in order |
| `extras/compile_fb/` | Optional helper: redact/summarize a compile-failure fixture |

Generated `out/` trees are omitted on purpose. Re-run the acceptance scripts
to produce them locally.

## Requirements

Windows PowerShell (the official parser and alias resolution). The extractor
is not a Linux/pwsh port. Execution policy: `Bypass` as shown below is only
for these scripts, and they still do not run the subject command.

## Quick start

From this folder:

```powershell
# End-to-end smoke (reads the package fixture README — the subject is not executed)
powershell -NoProfile -ExecutionPolicy Bypass -File .\Run-Chain.ps1

# Full acceptance (M1 writes m1-facts/out/, which M2 consumes)
powershell -NoProfile -ExecutionPolicy Bypass -File .\Run-Acceptance.ps1
```

Or module by module (run M1 before M2):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\m1-facts\Run-Acceptance.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\m2-claims\Run-Acceptance.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\m3-policy\Run-Acceptance.ps1
```

Optional compile-feedback summarizer (needs Python 3):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\extras\compile_fb\Summarize-CompileFeedback.ps1
```

## Single-command examples

```powershell
powershell -NoProfile -File .\m1-facts\Extract-CevFacts.ps1 -Command "del C:\temp\x -Recurse" -Pretty

powershell -NoProfile -File .\m2-claims\Compare-CevClaims.ps1 `
  -ClaimsFile .\m2-claims\samples\claims\C1_match_delete.claim.json `
  -FactsFile .\m1-facts\out\A1_alias_del_recurse.json `
  -Pretty

powershell -NoProfile -File .\m3-policy\Apply-CevPolicy.ps1 `
  -VerdictFile .\m3-policy\samples\verdicts\E4_delete_system.verdict.json `
  -Pretty
```

## What this is not

- Not a production host hook, sidecar, or “install and it is on” plugin
- Not the later host-coupled hotfixes that lived only in a private wiring
- Not a sandbox or a risk score; it returns a verdict plus structured facts
- Policy paths in this preview are examples and placeholders, not a real machine layout

If you want an agent host to call this before tool execution, see
`docs/HOST_INTEGRATION.md`. Keep production policy files out of a public repo.

## License

MIT. See `LICENSE` and `SECURITY.md`.
