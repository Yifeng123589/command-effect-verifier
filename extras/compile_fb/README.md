# extras/compile_fb — compile-failure summarizer

Optional helper, not part of the M1–M3 gate. It turns a **fixture** compiler
stderr file into a redacted structured summary and a short “next round”
prompt block. It does not run a compiler, does not execute subject commands,
and does not change gate verdicts.

## Layout

| Path | Notes |
|------|--------|
| `fixtures/tsc_fail_sample.stderr.txt` | Sample `tsc` failure (includes a secret-like probe and a long-line probe) |
| `summarize_compile_feedback.py` | Summarizer |
| `Summarize-CompileFeedback.ps1` | Thin PowerShell wrapper |
| `out/compile_fb_summary.json` | Written on run |
| `out/compile_fb_next_round.md` | Written on run |

## Run

From this directory (Python 3 required):

```powershell
python .\summarize_compile_feedback.py
# or
powershell -NoProfile -File .\Summarize-CompileFeedback.ps1
```

The summarizer drops lines that look like credentials, truncates very long
lines, and relativizes Windows user-profile prefixes in parsed paths.
