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

DR phase durations use contiguous boundaries, so their sum equals the business RTO:
  decision T0-T2 · restore/DB readiness T2-cutover start · secret patch/restart cutover start-T7 · validation T7-T9.

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


def load_events(path: Path) -> list:
    events = []
    for line in path.read_text().splitlines():
        if line.strip():
            event = json.loads(line)
            event["_ts"] = parse_ts(event["ts"])
            events.append(event)
    return events


def first_ts(events: list, marker: str):
    return next((event["_ts"] for event in events if event["marker"] == marker), None)


def note_number(note: str, key: str):
    match = re.search(rf"(?:^|\s){re.escape(key)}=([0-9]+(?:\.[0-9]+)?)", note or "")
    return float(match.group(1)) if match else None


def phase_timers(events: list) -> list:
    # Pair markers in file order; dr-run.sh does not repeat an already started phase after --resume.
    starts, timers = {}, []
    for event in events:
        marker = event["marker"]
        if marker.startswith("PHASE_START:"):
            starts.setdefault(marker.removeprefix("PHASE_START:"), event)
        elif marker.startswith("PHASE_END:"):
            name = marker.removeprefix("PHASE_END:")
            start = starts.pop(name, None)
            elapsed = note_number(event.get("note", ""), "elapsed_s")
            if elapsed is None and start:
                elapsed = (event["_ts"] - start["_ts"]).total_seconds()
            budget = note_number(start.get("note", ""), "budget_min") if start else None
            timers.append({
                "name": name,
                "start": start["ts"] if start else None,
                "end": event["ts"],
                "elapsed_s": round(elapsed, 1) if elapsed is not None else None,
                "budget_min": budget,
                "over_budget_s": round(max(elapsed - budget * 60, 0.0), 1)
                if elapsed is not None and budget is not None else None,
            })
    return timers


def phase_budget(timers: list, names: tuple):
    budgets = [timer["budget_min"] for timer in timers if timer["name"] in names and timer["budget_min"] is not None]
    return sum(budgets) if budgets else None


def dr_phases(t: dict, events: list, timers: list, rto_s):
    cutover_start = first_ts(events, "PHASE_START:cutover") or first_ts(events, "T6")
    specs = (
        ("failover_decision", "1. Failover decision", "T0 -> T2", t.get("T0"), t.get("T2"), ("prepare",)),
        ("restore", "2. Restore + DB readiness", "T2 -> cutover start", t.get("T2"), cutover_start,
         ("restore", "harden")),
        ("secret_patch_restart", "3. Secret patch + restart", "cutover start -> T7", cutover_start, t.get("T7"),
         ("cutover",)),
        ("validation", "4. Validation", "T7 -> T9", t.get("T7"), t.get("T9"), ("app-verify",)),
    )
    phases = []
    for key, label, boundary, start, end, budget_names in specs:
        duration = (end - start).total_seconds() if start and end and end >= start else None
        budget = phase_budget(timers, budget_names)
        phases.append({
            "key": key,
            "phase": label,
            "boundary": boundary,
            "duration_s": round(duration, 1) if duration is not None else None,
            "budget_min": budget,
            "over_budget_s": round(max(duration - budget * 60, 0.0), 1)
            if duration is not None and budget is not None else None,
            "share_of_rto_pct": round(duration * 100 / rto_s, 1) if duration is not None and rto_s else None,
        })
    measured = [phase for phase in phases if phase["duration_s"] is not None]
    bottleneck = max(measured, key=lambda phase: phase["duration_s"])["phase"] if measured else None
    return phases, bottleneck


def duration_cell(seconds):
    return human_duration(seconds) if seconds is not None else "n/a"


def budget_cell(minutes_value):
    return f"{minutes_value:g} min" if minutes_value is not None else "n/a"


def budget_status(over_budget_s):
    if over_budget_s is None:
        return "n/a"
    return "within budget" if over_budget_s == 0 else f"over by {human_duration(over_budget_s)}"


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


def operator_wait_min(path: Path, t0, t9):
    """Overlap of prompt/gate waits with the business RTO interval T0-T9."""
    secs = 0
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        ev = json.loads(line)
        m = re.search(r"secs=(\d+)", ev.get("note", ""))
        if ev["marker"] == "HUMAN_WAIT" and m and t0 and t9:
            wait_end = parse_ts(ev["ts"])
            wait_start = wait_end - timedelta(seconds=int(m.group(1)))
            overlap_start = max(wait_start, t0)
            overlap_end = min(wait_end, t9)
            if overlap_end > overlap_start:
                secs += (overlap_end - overlap_start).total_seconds()
    return round(round(secs) / 60, 2)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("timeline", type=Path)
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument("--rto-target-min", type=float, default=30)
    ap.add_argument("--rpo-target-s", type=float, default=86400)
    args = ap.parse_args()

    mk = load(args.timeline)
    events = load_events(args.timeline)
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
        "operator_wait_min": operator_wait_min(args.timeline, t.get("T0"), t.get("T9")),
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
    timers = phase_timers(events)
    rto_s = (t["T9"] - t["T0"]).total_seconds() if "T0" in t and "T9" in t else None
    report["dr_phases"], report["bottleneck_phase"] = dr_phases(t, events, timers, rto_s)
    report["phase_timers"] = timers
    rpo_actual_display = human_duration(report["rpo_actual_s"]) if report["rpo_actual_s"] is not None else "n/a"

    md = ["| KPI | Value | Target | Met |", "|---|---|---|---|",
          f"| Business RTO (T9-T0) | {rto} min | {args.rto_target_min} min | {report['rto_met']} |",
                    f"| RPO actual ({report['rpo_method']}) | {rpo_actual_display} | {human_duration(args.rpo_target_s)} | {report['rpo_met']} |",
          f"| Time to declare (T1-T0) | {report['time_to_declare_min']} min | | |",
          f"| Decision (T2-T1) | {report['decision_min']} min | 15 min | |",
          f"| DB recovery: promote/restore (T5-T4) | {report['db_recovery_min']} min | | |",
          f"| App recovery (T9-T5) | {report['app_recovery_min']} min | | |",
          f"| Of the RTO: waiting at prompts and gates (manual steps) | {report['operator_wait_min']} min | | |",
          f"| Missing markers | {', '.join(report['missing_markers']) or 'none'} | none | |"]
    md += ["", "## DR phase durations", "",
           "Wall-clock time from the timeline. The four phases are contiguous, so their sum equals the business RTO.",
           "Times include prompts, gates and operator waiting.", "",
           "| Phase | Boundary | Actual | Budget | Budget status | Share of RTO |", "|---|---|---|---|---|---|"]
    for phase in report["dr_phases"]:
        share = f"{phase['share_of_rto_pct']}%" if phase["share_of_rto_pct"] is not None else "n/a"
        md.append(f"| {phase['phase']} | {phase['boundary']} | {duration_cell(phase['duration_s'])} | "
                  f"{budget_cell(phase['budget_min'])} | {budget_status(phase['over_budget_s'])} | {share} |")
    md += ["", f"Main bottleneck: {report['bottleneck_phase'] or 'n/a'}", "",
           "## Runner phase timers", "",
           "| Timer | Actual | Budget | Budget status |", "|---|---|---|---|"]
    if timers:
        for timer in timers:
            md.append(f"| {timer['name']} | {duration_cell(timer['elapsed_s'])} | {budget_cell(timer['budget_min'])} | "
                      f"{budget_status(timer['over_budget_s'])} |")
    else:
        md.append("| none recorded | n/a | n/a | n/a |")

    print(json.dumps(report, indent=2))
    print("\n".join(md))
    if args.out:
        args.out.mkdir(parents=True, exist_ok=True)
        (args.out / "rto-rpo-report.json").write_text(json.dumps(report, indent=2))
        (args.out / "rto-rpo-report.md").write_text("\n".join(md) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
