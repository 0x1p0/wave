#!/usr/bin/env python3
"""Report for a guided gesture session (make session): per step, what you were asked to do vs what Wave
detected and would have done, with webcam frames for every detection and every strong rejected candidate.

    python3 scripts/session_report.py [SESSION_DIR]      (default: the newest session)

Writes SESSION_DIR/report.md and SESSION_DIR/sheets/<step>.png, and prints the summary.
"""
import json, os, pathlib, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parent
SESSIONS = pathlib.Path.home() / "Library/Application Support/Wave/Sessions"

def newest():
    dirs = sorted(d for d in SESSIONS.iterdir() if (d / "session.json").exists())
    return dirs[-1]

d = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else newest()
log = json.loads((d / "session.json").read_text())
camera = d / "camera"
(d / "sheets").mkdir(exist_ok=True)
lines = [f"# Session {d.name}", "", f"Layout: {log.get('layout')}", ""]
summary = []

def label(e):
    s = f"{e['kind']} {'OK' if e['outcome'] == 'accepted' else 'x ' + e['outcome']}"
    if e.get("lagMs") is not None:
        s += f" {e['lagMs']:+.0f}ms"
    return s[:38]

for st in log["steps"]:
    expect = st.get("expect", [])
    acc = [e for e in st["events"] if e["outcome"] == "accepted"]
    good = [e for e in acc if e["kind"] in expect]
    bad = [e for e in acc if e["kind"] not in expect]
    strong_rejects = [e for e in st["events"] if e["outcome"] != "accepted" and max(e["towardPeakDB"], e["awayPeakDB"]) >= 12]
    lines.append(f"## {st['title']}  ({st['start']:.1f}–{st['end']:.1f} s)")
    lines.append(f"Expected: {', '.join(expect) or 'nothing'} · correct {len(good)} · wrong {len(bad)} · rejected candidates {len(strong_rejects)}")
    if st.get("expectNote"):
        lines.append(f"Also expected: {st['expectNote']}")
    for e in st["events"]:
        mark = "✓" if e["outcome"] == "accepted" else "✗"
        verdict = "" if e["outcome"] != "accepted" else ("  OK" if e["kind"] in expect else "  <-- WRONG")
        extra = f" lag {e['lagMs']:+.0f}ms" if e.get("lagMs") is not None else ""
        extra += f" v {e.get('towardVelocity', 0):+.2f}/{e.get('awayVelocity', 0):+.2f}"
        extra += f" ref {e.get('referenceDB', 0):.1f}"
        act = f" → {e['action']}" if e.get("action") else ""
        lines.append(f"    {e['start']:7.2f}–{e['end']:7.2f} {mark} {e['kind']:<11} {e['outcome']:<30} ▲{e['towardPeakDB']:+5.1f} ▼{e['awayPeakDB']:+5.1f}{extra}{act}{verdict}")
    for c in st["controls"]:
        lines.append(f"    {c['time']:7.2f}  ⌁ {c['text']}")
    lines.append("")
    notes = [c["text"] for c in st["controls"] if "LEFT" in c["text"] or "RETURNED" in c["text"]]
    drawn = sum(1 for c in st["controls"] if "DRAWN" in c["text"])
    if drawn:
        notes.append(f"{drawn} drawing(s)")
    shown_expect = expect + ([st["expectNote"]] if st.get("expectNote") else [])
    summary.append((st["title"], shown_expect, len(good), len(bad), [f"{e['kind']}→{e.get('action')}" for e in bad] + notes))

    # Frames: before / during / after each accepted event and each strong rejected one.
    shown = sorted(acc + strong_rejects, key=lambda e: e["start"])[:16]
    if shown and camera.exists():
        args = []
        for e in shown:
            mid = (e["start"] + e["end"]) / 2
            args += [f"{e['start'] - 0.3:.2f}:before", f"{mid:.2f}:{label(e)}", f"{e['end'] + 0.25:.2f}:after"]
        out = d / "sheets" / f"{st['id']}.png"
        subprocess.run(["swift", str(ROOT / "contact-sheet.swift"), str(out), str(camera), "3", *args],
                       capture_output=True)
        lines.append(f"Frames: sheets/{st['id']}.png")
        lines.append("")

(d / "report.md").write_text("\n".join(lines))
print(f"Session {d.name}  ({log.get('layout')})\n")
print(f"{'Step':<26}{'expected':<26}{'correct':>8}{'wrong':>7}   wrong triggers")
for title, expect, good, bad, wrong in summary:
    print(f"{title:<26}{(', '.join(expect) or 'nothing'):<26}{good:>8}{bad:>7}   {', '.join(wrong)}")
print(f"\nFull report: {d / 'report.md'}")
