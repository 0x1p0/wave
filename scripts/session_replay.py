#!/usr/bin/env python3
"""Replays every step of a guided session through the CURRENT detector code and prints the same scoreboard
as session_report.py, so a fix can be checked against the recorded session before anyone tries it live.

    python3 scripts/session_replay.py [SESSION_DIR] [extra wave-probe replay flags, e.g. --no-grab]
"""
import json, pathlib, subprocess, sys, tempfile, collections

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROBE = ROOT / "build/DerivedData/Build/Products/Release/wave-probe"
SESSIONS = pathlib.Path.home() / "Library/Application Support/Wave/Sessions"
args = [a for a in sys.argv[1:] if not a.startswith("--")]
flags = [a for a in sys.argv[1:] if a.startswith("--")]
d = pathlib.Path(args[0]) if args else sorted(x for x in SESSIONS.iterdir() if (x / "session.json").exists())[-1]
log = json.loads((d / "session.json").read_text())
expect = {st["id"]: st.get("expect", []) for st in log["steps"]}
print(f"Replay of {d.name} with current code {' '.join(flags)}\n")
print(f"{'Step':<14}{'expected':<26}{'correct':>8}{'wrong':>7}   wrong (kind @ s)")
tot_good = tot_bad = 0
for caf in sorted(d.glob("wave-*.caf")):
    step = caf.stem.split("-", 3)[3]
    with tempfile.NamedTemporaryFile(suffix=".jsonl") as tmp:
        subprocess.run([str(PROBE), "replay", str(caf), "--json", tmp.name, *flags], capture_output=True)
        events = [json.loads(l) for l in open(tmp.name) if l.strip()]
    acc = [e for e in events if e["outcome"] == "accepted"]
    exp = expect.get(step, [])
    good = [e for e in acc if e["kind"] in exp]
    bad = [e for e in acc if e["kind"] not in exp]
    tot_good += len(good); tot_bad += len(bad)
    print(f"{step:<14}{(', '.join(exp) or 'nothing'):<26}{len(good):>8}{len(bad):>7}   " +
          ", ".join(f"{e['kind']}@{e['start']:.1f}" for e in bad))
print(f"\nTotal correct {tot_good}, wrong {tot_bad}")
