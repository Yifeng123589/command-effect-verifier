# Host integration (agnostic sketch)

This package does not ship a hook for any particular agent host. Installing
the files does not enable a gate. The note below is only the calling order a
host could follow **before** it executes a PowerShell tool call.

1. Require a paired structured declaration with the proposed command:
   free-text `intent` (display only) plus structured `claims` (compared).
   A command with no pair should not enter the execution queue.
2. Call `m1-facts/Extract-CevFacts.ps1` on the command **string**. Do not
   execute that command in this step.
3. Call `m2-claims/Compare-CevClaims.ps1` with the claims file and the facts
   JSON from step 2.
4. Call `m3-policy/Apply-CevPolicy.ps1` with that verdict and **your** copy
   of `policy/regions.json` and `matrix.json` (do not publish production
   paths).
5. Honor the verdict:
   - `pass` — the host may proceed under its own rules
   - `bounce` — return mechanical facts to the model for a rewrite; do not run
   - `human` — present facts and matched rules to a person; do not auto-run
   - `block` — hard stop; no later step, including model output, may downgrade it
6. Fail closed: if the gate itself errors, treat the result as human review,
   never as a silent pass. Cap bounce retries and then escalate.

Do not copy a private production pre-tool hook into this tree. Wire the
scripts above from the host you actually maintain, and keep secrets and
real machine policy out of the public package.
