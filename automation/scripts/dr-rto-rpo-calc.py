#!/usr/bin/env python3
"""Compute RTO/RPO KPIs from a DR timeline (timeline.jsonl written by dr_mark).

Markers (see docs/04-rpo-rto-measurement.md): T0 impact start, T1 declared, T2 G1 GO, T4 promote start,
T5 DB writable, T7 rollouts done, T9 service restored, T10 declared stable.
RPO inputs per scenario (markers, note field "value=<iso-ts>"):
  S1  : RPO_ZERO (synchronous Multi-AZ standby)                       -> RPO = 0
  S2  : RPO_LAST_REPLICATED (dr.heartbeat.ts on the promoted DB)
        RPO_LAST_PRIMARY_COMMIT (last heartbeat commit logged by writer) -> RPO = commit - replicated
  S3  : RPO_SNAPSHOT (SnapshotCreateTime)                              -> RPO = loss_end - snapshot
  S4  : RPO_RESTORE_TS (--restore-time used)                           -> RPO = loss_end - restore_ts
  loss_end = latest of T0 / DAMAGE_STOPPED / FENCE (writes accepted by the old primary after the restore
  point are lost unless reconciled).

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
    restore_point = val("RPO_RESTORE_TS") or val("RPO_SNAPSHOT")
    loss_end_candidates = [parse_ts(mk[m]["ts"]) for m in ("T0", "DAMAGE_STOPPED", "FENCE") if m in mk]
    rpo_s, rpo_method = None, None
    if "RPO_ZERO" in mk:
        rpo_s, rpo_method = 0.0, "multi-az synchronous"
    elif last_rep and last_commit:
        rpo_s, rpo_method = round((last_commit - last_rep).total_seconds(), 1), "heartbeat"
    elif restore_point and loss_end_candidates:
        rpo_s, rpo_method = round((max(loss_end_candidates) - restore_point).total_seconds(), 1), "restore point"

    report = {
        "dr_id": next(iter(mk.values()))["dr_id"] if mk else None,
        "business_rto_min": minutes(t.get("T0"), t.get("T9")),
        "time_to_declare_min": minutes(t.get("T0"), t.get("T1")),
        "decision_min": minutes(t.get("T1"), t.get("T2")),
        "db_recovery_min": minutes(t.get("T4"), t.get("T5")),
        "app_recovery_min": minutes(t.get("T5"), t.get("T9")),
        "execution_min": minutes(t.get("T2"), t.get("T10")),
        "rpo_actual_s": max(rpo_s, 0.0) if rpo_s is not None else None,
        "rpo_method": rpo_method,
        "scenario": next(iter(mk.values())).get("scenario") if mk else None,
        "rto_target_min": args.rto_target_min,
        "rpo_target_s": args.rpo_target_s,
        "missing_markers": [m for m in ("T0", "T1", "T2", "T4", "T5", "T9", "T10") if m not in t],
    }
    rto = report["business_rto_min"]
    report["rto_met"] = None if rto is None else rto <= args.rto_target_min
    report["rpo_met"] = None if report["rpo_actual_s"] is None else report["rpo_actual_s"] <= args.rpo_target_s

    md = ["| KPI | Value | Target | Met |", "|---|---|---|---|",
          f"| Business RTO (T9-T0) | {rto} min | {args.rto_target_min} min | {report['rto_met']} |",
          f"| RPO actual ({report['rpo_method']}) | {report['rpo_actual_s']} s | {args.rpo_target_s} s | {report['rpo_met']} |",
          f"| Time to declare (T1-T0) | {report['time_to_declare_min']} min | | |",
          f"| Decision (T2-T1) | {report['decision_min']} min | 15 min | |",
          f"| DB recovery: promote/restore (T5-T4) | {report['db_recovery_min']} min | | |",
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
