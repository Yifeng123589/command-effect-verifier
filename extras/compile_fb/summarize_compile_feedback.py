#!/usr/bin/env python3
# summarize_compile_feedback.py
# Preview helper: desensitized compile summary. Not a gate. Does not execute subject commands.
"""Summarize compile stderr fixture into structured JSON + next-round prompt."""

from __future__ import annotations

import argparse
import json
import re
from datetime import datetime
from pathlib import Path

# Credential-like line detector used only to drop fixture / log lines from the summary.
SECRET_RE = re.compile(
    r"api[_-]?key|secret|token|authorization|bearer\s+|sk-[A-Za-z0-9]{8,}|"
    r"AKIA[0-9A-Z]{8,}|\.env\b|password\s*=|SEALED",
    re.I,
)
RX_TSC = re.compile(
    r"^(?P<path>[^:(]+)\((?P<line>\d+)(?:,(?P<col>\d+))?\)\s*:\s*"
    r"(?P<sev>error|warning)\s+(?P<code>[A-Z]{0,4}\d+)\s*:\s*(?P<msg>.*)$"
)
RX_GEN = re.compile(
    r"^(?P<path>[^:]+):(?P<line>\d+)(?::(?P<col>\d+))?\s*:\s*"
    r"(?P<sev>error|warning)\s*:?\s*(?P<msg>.*)$"
)
# Relativize a Windows user-profile prefix without naming a real user or project.
HOME_ANY = re.compile(r"(?i)^[A-Za-z]:\\Users\\[^\\]+\\(.+)$")


def relativize(path: str) -> str:
    if not path:
        return path
    m = HOME_ANY.match(path)
    if m:
        return ".../" + m.group(1).replace("\\", "/")
    return path.replace("\\", "/")


def truncate(s: str, max_chars: int):
    if s is None:
        return "", False
    t = s.rstrip()
    if len(t) <= max_chars:
        return t, False
    return t[:max_chars] + "...", True


def summarize(stderr_file, exit_code, toolchain, max_key_lines, max_line_chars, max_errors):
    raw_lines = stderr_file.read_text(encoding="utf-8").splitlines()
    key_lines = []
    loci = []
    error_count = 0
    redacted = 0
    truncated_n = 0

    for line in raw_lines:
        if not line.strip():
            continue
        if line.startswith("tsc_fixture_v1"):
            continue
        if re.match(r"^Found \d+ errors", line):
            continue
        if SECRET_RE.search(line):
            redacted += 1
            continue
        if line.startswith("# LONG_LINE_PROBE"):
            _, was = truncate(line, max_line_chars)
            if was:
                truncated_n += 1
            continue

        m = RX_TSC.match(line) or RX_GEN.match(line)
        if not m or m.group("sev") != "error":
            continue

        error_count += 1
        if error_count > max_errors:
            continue

        rel = relativize(m.group("path").strip())
        ln = int(m.group("line"))
        col = m.groupdict().get("col")
        entry = {"path": rel, "line": ln}
        if col:
            entry["col"] = int(col)
        code = m.groupdict().get("code")
        if code:
            entry["code"] = code
        loci.append(entry)

        col_part = f",{col}" if col else ""
        code_part = f" {code}" if code else ""
        display = f"{rel}({ln}{col_part}): error{code_part}: {m.group('msg')}"
        trunc, was = truncate(display, max_line_chars)
        if was:
            truncated_n += 1
        if len(key_lines) < max_key_lines:
            key_lines.append(trunc)

    seen = set()
    loci_unique = []
    for lo in loci:
        k = f"{lo['path']}:{lo['line']}"
        if k not in seen:
            seen.add(k)
            loci_unique.append(lo)

    if loci_unique:
        loci_hint = ", ".join(f"{x['path']}:{x['line']}" for x in loci_unique)
    else:
        loci_hint = "(no loci parsed)"
    hint, _ = truncate(
        f"Next round: fix these loci first: {loci_hint}. "
        "Prefer type/missing-symbol fixes; do not rewrite whole files.",
        200,
    )

    return {
        "schema": "cev.compile_fb.v0",
        "stage": "compile_fb_preview",
        "subject_executed": False,
        "compile_exit": exit_code,
        "toolchain": toolchain,
        "error_count": min(error_count, max_errors),
        "key_lines": key_lines,
        "loci": loci_unique,
        "hint_for_llm": hint,
        "redaction": {
            "applied": True,
            "rule_version": "cev-compile-fb-redact-v0",
            "max_key_lines": max_key_lines,
            "max_line_chars": max_line_chars,
            "max_errors": max_errors,
            "secret_like_dropped": redacted,
            "truncated_lines": truncated_n,
        },
        "source_fixture": relativize(str(stderr_file)),
        "generated_at_asia_shanghai": datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        + " Asia/Shanghai",
    }


def render_prompt(summary):
    loci_md = []
    for lo in summary["loci"]:
        c = f":{lo['col']}" if "col" in lo else ""
        code = f" ({lo['code']})" if "code" in lo else ""
        loci_md.append(f"- `{lo['path']}:{lo['line']}{c}`{code}")
    if not loci_md:
        loci_md = ["- (none)"]
    key_md = [f"- `{k}`" for k in summary["key_lines"]] or ["- (none)"]
    return (
        "# CEV compile feedback · next-round prompt block (preview fixture)\n\n"
        "> Source: redacted structured summary from a sample compiler log. "
        "This does not change execution-gate verdicts.\n\n"
        "## Compile summary\n"
        f"- compile_exit: {summary['compile_exit']}\n"
        f"- toolchain: {summary['toolchain']}\n"
        f"- error_count: {summary['error_count']}\n"
        f"- redaction.applied: true (rule={summary['redaction']['rule_version']})\n\n"
        "## Key loci\n"
        + "\n".join(loci_md)
        + "\n\n## key_lines\n"
        + "\n".join(key_md)
        + "\n\n## hint_for_llm\n"
        + summary["hint_for_llm"]
        + "\n\n## Constraints for next round\n"
        "- Only edit the loci above; do not rewrite the whole repo; do not inject secrets or real user dialogue.\n"
        "- This block comes from a preview fixture, not a live compiler run.\n"
    )


def main():
    here = Path(__file__).resolve().parent
    ap = argparse.ArgumentParser(description="CEV compile-feedback summarizer (preview)")
    ap.add_argument("--stage-root", type=Path, default=here)
    ap.add_argument(
        "--stderr-file",
        type=Path,
        default=here / "fixtures" / "tsc_fail_sample.stderr.txt",
    )
    ap.add_argument("--exit-code", type=int, default=2)
    ap.add_argument("--toolchain", default="tsc@5")
    ap.add_argument("--out-json", type=Path, default=None)
    ap.add_argument("--out-prompt", type=Path, default=None)
    ap.add_argument("--max-key-lines", type=int, default=20)
    ap.add_argument("--max-line-chars", type=int, default=200)
    ap.add_argument("--max-errors", type=int, default=50)
    args = ap.parse_args()

    out_dir = args.stage_root / "out"
    out_dir.mkdir(parents=True, exist_ok=True)
    out_json = args.out_json or (out_dir / "compile_fb_summary.json")
    out_prompt = args.out_prompt or (out_dir / "compile_fb_next_round.md")

    summary = summarize(
        args.stderr_file,
        args.exit_code,
        args.toolchain,
        args.max_key_lines,
        args.max_line_chars,
        args.max_errors,
    )
    out_json.write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    out_prompt.write_text(render_prompt(summary) + "\n", encoding="utf-8")
    print(
        "COMPILE_FB_OK exit={exit} errors={err} loci={loci} key_lines={kl} "
        "redacted={r} truncated={t}".format(
            exit=summary["compile_exit"],
            err=summary["error_count"],
            loci=len(summary["loci"]),
            kl=len(summary["key_lines"]),
            r=summary["redaction"]["secret_like_dropped"],
            t=summary["redaction"]["truncated_lines"],
        )
    )
    print(f"JSON -> {out_json}")
    print(f"PROMPT -> {out_prompt}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
