#!/usr/bin/env python3
"""Compute RTO/RPO KPIs from a DR timeline (timeline.jsonl written by dr_mark).

Markers (see docs/04-rpo-rto-measurement.md): T0 impact start, T1 declared, T2 G1 GO, T4 promote start,
T5 DB writable, T7 rollouts done, T8 app connectivity restored, T9 business validation passed, T10 declared stable.
RPO inputs per scenario (markers, note field "value=<iso-ts>"):
  S1  : RPO_ZERO (synchronous Multi-AZ standby)                       -> RPO = 0
  S2  : RPO_LAST_REPLICATED (dr.heartbeat.ts on the promoted DB)
        RPO_LAST_PRIMARY_COMMIT (last heartbeat commit logged by writer) -> RPO = commit - replicated
  S3  : RPO_SNAPSHOT (SnapshotCreateTime)                              -> RPO = loss_end - snapshot
  S4  : RPO_RESTORE_TS (--restore-time used)                           -> RPO = loss_end - restore_ts
  loss_end = latest of T0 / DAMAGE_STOPPED / FENCE (writes accepted by the old primary after the restore
  point are lost unless reconciled).

Usage: dr-rto-rpo-calc.py timeline.jsonl [--out DIR] [--rto-target-min 30] [--rpo-target-s 86400]
"""
import argparse
import json
import re
import sys
from datetime import datetime, timedelta
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


def human_duration(seconds: float) -> str:
    total_seconds = max(0.0, float(seconds))
    days, remainder = divmod(total_seconds, 86400)
    hours, remainder = divmod(remainder, 3600)
    minutes, remaining_seconds = divmod(remainder, 60)
    parts = []
    if days:
        parts.append(f"{int(days)} d")
    if hours:
        parts.append(f"{int(hours)} h")
    if minutes:
        parts.append(f"{int(minutes)} min")
    if remaining_seconds or not parts:
        seconds_text = f"{remaining_seconds:.1f}".rstrip("0").rstrip(".")
        parts.append(f"{seconds_text} s")
    return " ".join(parts)


def operator_wait_min(path: Path, t0, t8):
    """Overlap of prompt/gate waits with the Service RTO interval T0-T8."""
    secs = 0
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        ev = json.loads(line)
        m = re.search(r"secs=(\d+)", ev.get("note", ""))
        if ev["marker"] == "HUMAN_WAIT" and m and t0 and t8:
            wait_end = parse_ts(ev["ts"])
            wait_start = wait_end - timedelta(seconds=int(m.group(1)))
            overlap_start = max(wait_start, t0)
            overlap_end = min(wait_end, t8)
            if overlap_end > overlap_start:
                secs += (overlap_end - overlap_start).total_seconds()
    return round(round(secs) / 60, 2)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("timeline", type=Path)
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument("--rto-target-min", type=float, default=30)
    ap.add_argument("--rpo-target-s", type=float, default=86400)
    ap.add_argument("--summary", action="store_true", help="print the interactive timeline summary only")
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
        "dr_id": next(iter(mk.values())).get("dr_id") if mk else None,
        "service_rto_min": minutes(t.get("T0"), t.get("T8")),
        "business_validation_min": minutes(t.get("T8"), t.get("T9")),
        "total_to_business_validation_min": minutes(t.get("T0"), t.get("T9")),
        "time_to_declare_min": minutes(t.get("T0"), t.get("T1")),
        "decision_min": minutes(t.get("T1"), t.get("T2")),
        "db_recovery_min": minutes(t.get("T4"), t.get("T5")),
        "app_recovery_min": minutes(t.get("T5"), t.get("T8")),
        "execution_min": minutes(t.get("T2"), t.get("T10")),
        "operator_wait_min": operator_wait_min(args.timeline, t.get("T0"), t.get("T8")),
        "rpo_actual_s": max(rpo_s, 0.0) if rpo_s is not None else None,
        "rpo_method": rpo_method,
        "scenario": next(iter(mk.values())).get("scenario") if mk else None,
        "rto_target_min": args.rto_target_min,
        "rpo_target_s": args.rpo_target_s,
        "missing_markers": [m for m in ("T0", "T1", "T2", "T4", "T5", "T8", "T9", "T10") if m not in t],
    }
    rto = report["service_rto_min"]
    report["rto_met"] = None if rto is None else rto <= args.rto_target_min
    report["rpo_met"] = None if report["rpo_actual_s"] is None else report["rpo_actual_s"] <= args.rpo_target_s
    rpo_actual_display = human_duration(report["rpo_actual_s"]) if report["rpo_actual_s"] is not None else "n/a"

    phase_lines = []
    for marker, event in mk.items():
        if not marker.startswith("PHASE_END:"):
            continue
        match = re.fullmatch(r"elapsed_s=(\d+)", event.get("note", ""))
        elapsed = human_duration(int(match.group(1))) if match else event.get("note", "")
        phase_lines.append(f"{marker.removeprefix('PHASE_END:')}: {elapsed}")
    t0 = t.get("T0")
    t8 = t.get("T8")
    t9 = t.get("T9")
    summary_lines = ["Phase durations (wall-clock; include prompts and gates):", *phase_lines]
    summary_lines.append(
        f"Operator wait within Service RTO (T0-T8): {human_duration(report['operator_wait_min'] * 60)}"
        if t8 else f"Operator wait since T0 (T8 not recorded): {human_duration(report['operator_wait_min'] * 60)}"
    )
    summary_lines.append(
        f"Service RTO (T0-T8): {human_duration((t8 - t0).total_seconds())} (RTO target: {args.rto_target_min:g} min)"
        if t0 and t8 else "Service recovery pending; T8 not recorded."
    )
    summary_lines.append(
        f"Business validation after Service RTO (T8-T9): {human_duration((t9 - t8).total_seconds())}"
        if t8 and t9 else "Business validation (T9) pending; continue validation after Service RTO."
    )

    if args.summary:
        print("\n".join(summary_lines))
        return 0

    md = ["| KPI | Value | Target | Met |", "|---|---|---|---|",
          f"| Service RTO (T8-T0) | {rto} min | {args.rto_target_min} min | {report['rto_met']} |",
                    f"| RPO actual ({report['rpo_method']}) | {rpo_actual_display} | {human_duration(args.rpo_target_s)} | {report['rpo_met']} |",
          f"| Time to declare (T1-T0) | {report['time_to_declare_min']} min | | |",
          f"| Decision (T2-T1) | {report['decision_min']} min | 15 min | |",
          f"| DB recovery: promote/restore (T5-T4) | {report['db_recovery_min']} min | | |",
          f"| App recovery (T8-T5) | {report['app_recovery_min']} min | | |",
          f"| Business validation after RTO (T9-T8) | {report['business_validation_min']} min | | |",
          f"| Total through business validation (T9-T0) | {report['total_to_business_validation_min']} min | | |",
          f"| Of the Service RTO: waiting at prompts and gates (manual steps) | {report['operator_wait_min']} min | | |",
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
