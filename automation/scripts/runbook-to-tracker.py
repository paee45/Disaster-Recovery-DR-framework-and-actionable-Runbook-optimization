#!/usr/bin/env python3
"""Generate an execution-tracker CSV (Google Sheets / Excel) from a runbook's step tables.

The Git runbook stays the single source of truth; the sheet is a generated, disposable execution aid.
Rows are taken from Markdown table lines whose first cell is a step/gate ID (P2-S05, P3A-S01, CP01-S04, P1-G1, ...).
Rows that reference a common procedure (CP-0x) are expanded with that procedure's steps when --expand is given.

Usage: runbook-to-tracker.py runbooks/prod/RB-PROD-S2-replica-promotion.md [--expand] [-o tracker.csv]
"""
import argparse
import csv
import re
import sys
from pathlib import Path

ID_RE = re.compile(r"^(P\d+[A-Z]?-(S|G)\d+|CP\d{2}-(S|G)\d+)")
CP_LINK_RE = re.compile(r"\((?:\.\./)*common/(CP-\d{2}[^)#]*\.md)")
HEADER = ["Step ID", "Step", "Owner", "Budget (min)", "Expected / verify", "Irreversible", "Parallel",
          "Status", "Assignee", "Start UTC", "End UTC", "Verified by (2nd eyes)", "Evidence link", "Deviation / notes"]


def strip_md(s: str) -> str:
    s = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", s)
    return s.replace("`", "").replace("**", "").replace("<br>", " / ").strip()


def rows(md_path: Path, expand: bool, seen=None):
    seen = seen or set()
    for line in md_path.read_text(encoding="utf-8").splitlines():
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 5:
            continue
        raw_id = cells[0]
        m = ID_RE.match(raw_id.replace("⛳", "").strip())
        if not m:
            continue
        step_id = m.group(0)
        yield [step_id, strip_md(cells[1]), strip_md(cells[2]), strip_md(cells[3]), strip_md(cells[4]),
               "Y" if "⚠" in raw_id else "", "Y" if "‖" in raw_id else "",
               "Not started", "", "", "", "", "", ""]
        if expand:
            for cp in CP_LINK_RE.findall(cells[1]):
                cp_path = (md_path.parent / ".." / "common" / cp).resolve()
                if cp_path.exists() and cp_path not in seen:
                    seen.add(cp_path)
                    yield from rows(cp_path, False, seen)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("runbook", type=Path)
    ap.add_argument("--expand", action="store_true", help="inline the steps of referenced common procedures")
    ap.add_argument("-o", "--out", type=Path)
    a = ap.parse_args()
    out = a.out.open("w", newline="", encoding="utf-8") if a.out else sys.stdout
    w = csv.writer(out)
    w.writerow(HEADER)
    n = 0
    for r in rows(a.runbook, a.expand):
        w.writerow(r)
        n += 1
    print(f"{n} rows from {a.runbook}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
