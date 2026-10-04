#!/usr/bin/env python3
"""Compute RTO/RPO KPIs from a DR timeline (timeline.jsonl written by dr_mark).

Markers (see docs/04-rpo-rto-measurement.md): T0 impact start, T1 declared, T2 G1 GO, T4 promote start,
T5 DB writable, T7 rollouts done, T9 service restored, T10 declared stable.
RPO inputs (optional markers, note field "value=<iso-ts>"):
  RPO_LAST_REPLICATED  - dr.heartbeat.ts read on the new primary
  RPO_LAST_PRIMARY_COMMIT - last successful heartbeat write logged by the writer job

Usage: dr-rto-rpo-calc.py timeline.jsonl [--out DIR] [--rto-target-min 60] [--rpo-target-s 300]
"""
import argparse
import json
import re
import sys
from datetime import datetime
from pathlib import Path


def parse_ts(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def load(path: Path) -> dict:
    markers = {}
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        ev = json.loads(line)
        m = ev["marker"]
        # last write wins: allows correcting a marker (e.g. back-filled T0) by re-marking it
        markers[m] = ev
    return markers


def minutes(a, b):
    return round((b - a).total_seconds() / 60, 2) if a and b else None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("timeline", type=Path)
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument("--rto-target-min", type=float, default=60)
    ap.add_argument("--rpo-target-s", type=float, default=300)
    args = ap.parse_args()

    mk = load(args.timeline)
    t = {k: parse_ts(v["ts"]) for k, v in mk.items() if re.fullmatch(r"T\d+", k)}

    def val(marker):
        ev = mk.get(marker)
        if not ev:
            return None
        m = re.search(r"value=(\S+)", ev.get("note", ""))
        return parse_ts(m.group(1)) if m else None

    last_rep, last_commit = val("RPO_LAST_REPLICATED"), val("RPO_LAST_PRIMARY_COMMIT")
    rpo_s = round((last_commit - last_rep).total_seconds(), 1) if last_rep and last_commit else None

    report = {
        "dr_id": next(iter(mk.values()))["dr_id"] if mk else None,
        "business_rto_min": minutes(t.get("T0"), t.get("T9")),
        "time_to_declare_min": minutes(t.get("T0"), t.get("T1")),
        "decision_min": minutes(t.get("T1"), t.get("T2")),
        "db_promotion_min": minutes(t.get("T4"), t.get("T5")),
        "app_recovery_min": minutes(t.get("T5"), t.get("T9")),
        "execution_min": minutes(t.get("T2"), t.get("T10")),
        "rpo_actual_s": max(rpo_s, 0.0) if rpo_s is not None else None,
        "rto_target_min": args.rto_target_min,
        "rpo_target_s": args.rpo_target_s,
        "missing_markers": [m for m in ("T0", "T1", "T2", "T4", "T5", "T9", "T10") if m not in t],
    }
    rto = report["business_rto_min"]
    report["rto_met"] = None if rto is None else rto <= args.rto_target_min
    report["rpo_met"] = None if report["rpo_actual_s"] is None else report["rpo_actual_s"] <= args.rpo_target_s

    md = ["| KPI | Value | Target | Met |", "|---|---|---|---|",
          f"| Business RTO (T9-T0) | {rto} min | {args.rto_target_min} min | {report['rto_met']} |",
          f"| RPO actual | {report['rpo_actual_s']} s | {args.rpo_target_s} s | {report['rpo_met']} |",
          f"| Time to declare (T1-T0) | {report['time_to_declare_min']} min | | |",
          f"| Decision (T2-T1) | {report['decision_min']} min | 15 min | |",
          f"| DB promotion (T5-T4) | {report['db_promotion_min']} min | | |",
          f"| App recovery (T9-T5) | {report['app_recovery_min']} min | | |",
          f"| Missing markers | {', '.join(report['missing_markers']) or 'none'} | none | |"]

    print(json.dumps(report, indent=2))
    print("\n".join(md))
    if args.out:
        args.out.mkdir(parents=True, exist_ok=True)
        (args.out / "rto-rpo-report.json").write_text(json.dumps(report, indent=2))
        (args.out / "rto-rpo-report.md").write_text("\n".join(md) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
