# Security

This preview package is a local, offline Command Effect Verifier. It does not
execute the subject command, does not call a language model, and ships with no
credentials, tokens, or host-integration secrets.

## Policy files are examples

`m3-policy/policy/regions.json` and `matrix.json` are **sample** policy data.
Project and backup patterns use the portable placeholder `${CEV_FIXTURE_ROOT}`,
which `Apply-CevPolicy.ps1` expands to this package's `m3-policy/fixtures/root`
at runtime. The sample user region is `C:\Users\Example`.

Do not paste production machine paths, usernames, or credentials into a public
fork of these files. If you adapt the matrix for a real host, keep that policy
private and review it separately.

## Verdicts are not a sandbox

A `pass` verdict only means claims matched extracted facts and no sample policy
rule fired. It is not a sandbox, VM, or proof that a command is safe to run.
`block` must not be downgraded by a later step. Plugin failures should fail
closed (treat as human review), never as a silent pass.

## This is a preview

Installing these files is not the same as enabling a gate. The package does
not include a production agent-host hook. See `docs/HOST_INTEGRATION.md` for a
host-agnostic calling order only.
