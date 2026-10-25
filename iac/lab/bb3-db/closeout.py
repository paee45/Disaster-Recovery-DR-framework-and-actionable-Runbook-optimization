import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile


REQUIRED = ("incident.json", "cutover.json", "fence.json", "app-deploy.json",
            "app-health.json", "app-e2e.json")
OPTIONAL = ("network-fence.json", "app-deploy.log", "run-report.md", "snapshot-recovery.json")
LIMITS = ("Partial local evidence only. Owner attestations are not independent validation. "
          "No live AWS verification or upload was performed. Baseline/raw API evidence is "
          "not bundled automatically and remains separate/pending. Snapshot-based RPO uses "
          "snapshot metadata, not transaction-level data verification. This is not full audit "
          "evidence or business certification.")


def utc_now():
    return datetime.now(timezone.utc)


def timestamp(value):
    if not isinstance(value, str):
        raise ValueError("A UTC ISO-8601 timestamp is required.")
    try:
        result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise ValueError("A UTC ISO-8601 timestamp is required.") from None
    if result.tzinfo is None or result.utcoffset() != timedelta(0):
        raise ValueError("Timestamps must include UTC timezone.")
    return result


def question_prompt(value):
    if (sys.stdin.isatty() and sys.stdout.isatty() and "NO_COLOR" not in os.environ
            and os.environ.get("TERM", "dumb") != "dumb"):
        return f"\033[1;33m{value}\033[0m"
    return value


def token_prompt(before, token, after):
    if (sys.stdin.isatty() and sys.stdout.isatty() and "NO_COLOR" not in os.environ
            and os.environ.get("TERM", "dumb") != "dumb"):
        return f"\033[1;33m{before}\033[1;35m{token}\033[1;33m{after}\033[0m"
    return before + token + after


def text(value):
    if not isinstance(value, str) or not value.strip() or any(ord(char) < 32 for char in value):
        raise ValueError("Nonblank single-line owner/reference/text is required; do not enter secrets.")
    return value.strip()


def digest(content):
    return hashlib.sha256(content).hexdigest()


def safe_path(path):
    path = Path(os.path.abspath(path))
    for ancestor in (path, *path.parents):
        if ancestor.is_symlink():
            raise ValueError("Symlinks are not allowed in evidence paths.")
    return path


def read_regular(path):
    path = safe_path(path)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError("Evidence must be a regular file.")
        return stream.read()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate journal JSON key.")
        result[key] = value
    return result


def decode(content):
    result = json.loads(content, object_pairs_hook=unique_object)
    if not isinstance(result, dict):
        raise ValueError("Journal must be a JSON object.")
    return result


def encoded(record):
    return (json.dumps(record, indent=2, allow_nan=False) + "\n").encode()


def exclusive_write(path, content):
    path = safe_path(path)
    descriptor, name = tempfile.mkstemp(prefix=".closeout-", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.link(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def git_ignored(root, path):
    result = subprocess.run(["git", "-C", str(root), "check-ignore", "-q", "--", str(path)],
                            capture_output=True, check=False)
    return result.returncode == 0


class Closeout:
    def __init__(self, root, ledger, run_id, account, region, environment):
        if not re.fullmatch(r"DR-[A-Za-z0-9_-]{1,120}", run_id):
            raise ValueError("Invalid explicit DR run ID.")
        if (not re.fullmatch(r"[0-9]{12}", account) or region != "ap-southeast-1"
                or environment not in ("dev", "uat")):
            raise ValueError("Only dev/uat sandbox identity is allowed.")
        self.root = safe_path(root)
        self.ledger = safe_path(ledger)
        self.run = safe_path(self.ledger / run_id)
        if not self.run.is_dir():
            raise ValueError("Selected run directory does not exist.")
        self.identity = dict(runId=run_id, account=account, region=region)
        self.environment = environment
        self.snapshot_evidence = None
        try:
            self.rto_target_minutes = float(os.environ.get("BB3_RTO_TARGET_MIN", "60"))
        except ValueError:
            raise ValueError("BB3_RTO_TARGET_MIN must be a positive number of minutes.") from None
        if not math.isfinite(self.rto_target_minutes) or self.rto_target_minutes <= 0:
            raise ValueError("BB3_RTO_TARGET_MIN must be a positive finite number of minutes.")

    def capture_snapshot(self, snapshot, source_db, restored_primary, snapshot_id):
        restored_primary = text(restored_primary)
        if (snapshot.get("DBSnapshotIdentifier") != text(snapshot_id)
                or snapshot.get("DBInstanceIdentifier") != text(source_db)
                or snapshot.get("Status") != "available"
                or snapshot.get("SnapshotType") not in ("automated", "manual")
                or not re.fullmatch(r"[A-Za-z][A-Za-z0-9-]{0,62}", restored_primary)):
            raise ValueError("Snapshot metadata must match the selected source and restore target.")
        created = timestamp(snapshot.get("SnapshotCreateTime"))
        network = decode(read_regular(self.run / "network-fence.json"))
        self.identify(network)
        if network.get("activePrimary") != source_db or network.get("status") != "attached":
            raise ValueError("Snapshot source must match the attached run quarantine.")
        if (self.run / "closeout.json").exists():
            raise ValueError("Snapshot evidence cannot change after service-restored approval.")
        evidence = dict(self.identity, environment=self.environment, status="selected-for-restore",
                        snapshotId=snapshot_id, snapshotCreatedAt=created.isoformat(),
                        snapshotType=snapshot["SnapshotType"], sourceDb=source_db,
                        restoredPrimary=restored_primary, metadataSource="rds describe-db-snapshots")
        path = self.run / "snapshot-recovery.json"
        if path.exists() or path.is_symlink():
            if decode(read_regular(path)) != evidence:
                raise ValueError("Saved snapshot evidence differs; no overwrite is allowed.")
        else:
            exclusive_write(path, encoded(evidence))
        return evidence

    def recovery_metrics(self, times):
        t0, _, t8, _ = times
        rto_seconds = (t8 - t0).total_seconds()
        rpo = dict(status="not-verified", basis="snapshot-age", targetSeconds=86400,
                   businessDataVerified=False)
        if self.snapshot_evidence is not None:
            snapshot_time = timestamp(self.snapshot_evidence["snapshotCreatedAt"])
            seconds = (t0 - snapshot_time).total_seconds()
            if seconds < 0:
                raise ValueError("Snapshot creation time cannot be later than impact T0.")
            rpo.update(status="verified", snapshotId=self.snapshot_evidence["snapshotId"],
                       snapshotCreatedAt=snapshot_time.isoformat(), impactAt=t0.isoformat(),
                       actualSeconds=seconds, met=seconds <= 86400)
        return dict(rtoTargetMinutes=self.rto_target_minutes,
                    serviceRtoMinutes=rto_seconds / 60,
                    rtoMet=rto_seconds <= self.rto_target_minutes * 60, rpo=rpo)

    def identify(self, record, deployment=False):
        for key, expected in self.identity.items():
            if deployment and key in ("account", "region") and key not in record:
                continue
            if record.get(key) != expected:
                raise ValueError("Journal identity mismatch: " + key)
        for key in ("environment", "env"):
            if key in record and record[key] != self.environment:
                raise ValueError("Journal environment mismatch.")

    def load(self):
        contents = {name: read_regular(self.run / name) for name in REQUIRED}
        records = {name: decode(content) for name, content in contents.items()}
        for name, record in records.items():
            self.identify(record, deployment=name == "app-deploy.json")
            expected = "declared" if name == "incident.json" else (
                "complete" if name == "cutover.json" else "owner-confirmed")
            if record.get("status") != expected:
                raise ValueError("Invalid status: " + name)
        incident = records["incident.json"]
        cutover = records["cutover.json"]
        fence = records["fence.json"]
        deployment = records["app-deploy.json"]
        health = records["app-health.json"]
        e2e = records["app-e2e.json"]
        if incident.get("scenario") != "S3" or incident.get("environment") != self.environment:
            raise ValueError("A matching S3 incident is required.")
        if cutover.get("operation") != "cutover":
            raise ValueError("A completed cutover operation is required.")
        if fence.get("fenceVerified") is not True or fence.get("existingSessionsClosed") is not True:
            raise ValueError("Verified fence and closed sessions are required.")
        for fence_key, cutover_key in (("activePrimary", "source_db"), ("activeReplica", "source_replica"),
                                        ("returnPrimary", "db"), ("returnReplica", "replica")):
            if text(fence.get(fence_key)) != text(cutover.get(cutover_key)):
                raise ValueError("Fence database pair does not match cutover.")
        text(fence.get("appOwner"))
        if (deployment.get("servicesConverged") is not True or health.get("connectivityVerified") is not True
                or e2e.get("transactionSucceeded") is not True):
            raise ValueError("Convergence, connectivity and successful transaction are required.")
        owner = text(deployment.get("appOwner"))
        for record in (deployment, health):
            text(record.get("evidenceRef"))
            for key, target in (("primaryHost", "newHost"), ("replicaHost", "newReplicaHost")):
                if text(record.get(key)) != text(cutover.get(target)):
                    raise ValueError("App attestation endpoints do not match cutover.")
        if text(health.get("appOwner")) != owner or text(e2e.get("appOwner")) != owner:
            raise ValueError("App attestation owners do not match.")
        text(incident.get("t0EvidenceRef"))
        text(e2e.get("transactionRef"))
        t0 = timestamp(incident.get("t0At"))
        t1 = timestamp(incident.get("t1At"))
        t8 = timestamp(health.get("t8At"))
        t9 = timestamp(e2e.get("t9At"))
        if (timestamp(health.get("t0At")) != t0 or timestamp(e2e.get("t0At")) != t0
                or timestamp(e2e.get("t8At")) != t8 or not t0 <= t1 <= t8 <= t9):
            raise ValueError("Inconsistent T0/T1/T8/T9 sequence.")
        if t9 > utc_now() + timedelta(seconds=60):
            raise ValueError("T9 is in the future.")
        self.snapshot_evidence = None
        for name in OPTIONAL:
            path = self.run / name
            if path.exists() or path.is_symlink():
                contents[name] = read_regular(path)
                if name == "network-fence.json":
                    network = decode(contents[name])
                    self.identify(network)
                    if network.get("status") != "attached":
                        raise ValueError("Network fence is not attached.")
                    for key in ("activePrimary", "activeReplica"):
                        if network.get(key) != fence.get(key):
                            raise ValueError("Network fence pair mismatch.")
                elif name == "snapshot-recovery.json":
                    evidence = decode(contents[name])
                    self.identify(evidence)
                    if (evidence.get("status") != "selected-for-restore"
                            or evidence.get("sourceDb") != cutover["source_db"]
                            or evidence.get("restoredPrimary") != cutover["db"]
                            or evidence.get("snapshotType") not in ("automated", "manual")
                            or evidence.get("metadataSource") != "rds describe-db-snapshots"):
                        raise ValueError("Snapshot evidence does not match this recovery pair.")
                    text(evidence.get("snapshotId"))
                    timestamp(evidence.get("snapshotCreatedAt"))
                    self.snapshot_evidence = evidence
        self.recovery_metrics((t0, t1, t8, t9))
        return records, contents, (t0, t1, t8, t9)

    def summary(self, times, color=False):
        t0, t1, t8, t9 = times
        rto_minutes = (t8 - t0).total_seconds() / 60
        validation_minutes = (t9 - t8).total_seconds() / 60
        total_minutes = (t9 - t0).total_seconds() / 60
        use_color = (color and sys.stdout.isatty() and "NO_COLOR" not in os.environ
                 and os.environ.get("TERM", "dumb") != "dumb")
        heading = "\033[1;35m" if use_color else ""
        cyan = "\033[1;36m" if use_color else ""
        green = "\033[1;32m" if use_color else ""
        red = "\033[1;31m" if use_color else ""
        yellow = "\033[1;33m" if use_color else ""
        reset = "\033[0m" if use_color else ""
        target = self.rto_target_minutes
        result_color = green if rto_minutes <= target else red
        result = "PASS" if rto_minutes <= target else "MISS"
        outcome = (f"The {target:g}-minute service recovery target was met ({rto_minutes:.2f} min)."
               if rto_minutes <= target else
               f"The {target:g}-minute service recovery target was exceeded by {rto_minutes - target:.2f} min.")
        rpo = self.recovery_metrics(times)["rpo"]
        if rpo["status"] == "verified":
            rpo_result = "PASS" if rpo["met"] else "MISS"
            rpo_color = green if rpo["met"] else red
            rpo_lines = [
                f"{rpo_color}RPO: VERIFIED (snapshot-based) | {rpo_result} | Target: 24 hours{reset}",
                f"  Snapshot: {rpo['snapshotId']}",
                f"  Snapshot creation time: {rpo['snapshotCreatedAt']}",
                f"  Snapshot age at impact T0: {rpo['actualSeconds'] / 3600:.2f} hours",
                "  Calculation: impact T0 minus the selected restore snapshot creation time.",
                "  Verified against saved AWS snapshot metadata for this source/restore pair.",
                "  This is the agreed snapshot-age measure, not proof of zero data loss.",
                "  DB/business transaction-level data completeness verification is deferred.",
            ]
        else:
            rpo_lines = [
                f"{yellow}RPO: NOT VERIFIED | Target: no more than 24 hours of data loss{reset}",
                "  No run-bound restore snapshot metadata was saved for this run.",
                "  Without its creation time, we cannot report a snapshot-age RPO pass/fail.",
                "  NOT VERIFIED does not mean zero loss, and does not itself mean a failure.",
                "  DB/business transaction-level data completeness verification is deferred.",
            ]
        stamp = lambda value: value.isoformat().replace("+00:00", "Z")
        lines = [
            heading + "=" * 76,
            "STAGE: P4-G4 | Service Restored Approval" + reset,
            f"{heading}RUN ID: {self.identity['runId']}{reset}",
            heading + "=" * 76 + reset,
            "",
            f"{result_color}RECOVERY TIMING RESULT: RTO {result} | {rto_minutes:.2f} min / {target:g} min target{reset}",
            f"  {outcome}",
            "  Health and business milestones below are owner-attested evidence.",
            "  Service approval does not turn a missed target into a pass.",
            "",
            f"{cyan}TIMELINE & RTO METRICS{reset}",
            "  T means a recorded milestone; T0 is T-zero, not the letters TO.",
            "  RTO is a duration: T8 health time minus T0 impact time.",
            "",
            f"{heading}  T0 (Impact) - SERVICE IMPACT START / RTO CLOCK STARTS{reset}",
            f"    Time (UTC): {cyan}{stamp(t0)}{reset}",
            "    Service impact began, supported by the saved app/monitor reference.",
            "    This is the start of the recovery clock, not when this script started.",
            "    Operator pauses, declaration, primary/replica restore and app recovery",
            "    after this point all count until the successful T8 app health check.",
            "",
            f"{heading}  T1 (Declared) - RECOVERY RESPONSE FORMALLY DECLARED{reset}",
            f"    Time (UTC): {cyan}{stamp(t1)}{reset}",
            f"    Time to declare (T1-T0): {cyan}{(t1-t0).total_seconds()/60:.2f} min{reset}",
            "    The S3 recovery was formally declared. Declaration time is included",
            "    in service RTO; declaring the incident does not restart the clock.",
            "    This milestone shows how long it took to declare recovery after impact;",
            "    it does not mean the DB or application was already restored.",
            "",
            f"{heading}  T8 (Health) - APP HEALTH RESTORED / RTO CLOCK ENDS{reset}",
            f"    Time (UTC): {cyan}{stamp(t8)}{reset}",
            f"    {result_color}SERVICE RTO (T8-T0): {rto_minutes:.2f} min | {result} | Target: {target:g} min{reset}",
            "    The app owner confirmed a successful health check using the recovered",
            "    DB endpoints. This ends service RTO; DB availability alone is not T8.",
            "    T8 is a timestamp, not another spelling of RTO. The duration from",
            "    T0 to this health check is compared with the configured RTO target.",
            "",
            f"{heading}  T9 (Business) - BUSINESS TRANSACTION / READBACK CONFIRMED{reset}",
            f"    Time (UTC): {cyan}{stamp(t9)}{reset}",
            f"    Additional validation (T9-T8): {cyan}{validation_minutes:.2f} min{reset}",
            "    The app owner confirmed a successful business transaction and readback.",
            "    This is additional validation after health recovery, not the RTO endpoint.",
            "    A successful new transaction confirms the recovered application workflow;",
            "    it does not verify that all pre-incident business data was recovered.",
            f"{cyan}  Total through T9: {total_minutes:.2f} min{reset}",
            "    Total elapsed from impact through business validation, including pauses.",
            "",
            *rpo_lines,
            "",
            f"{cyan}P4-G4 / T10: FORMAL SERVICE-RESTORED APPROVAL{reset}",
            "  The approver reviews deployment, health, business evidence and remaining",
            "  risks before sign-off. T10 is separate from T8 and does not change RTO.",
        ]
        return "\n".join(lines) + "\n"

    def ask(self, prompt):
        return text(input(question_prompt(prompt + " (no secrets): ")))

    def declare(self):
        print(f"P4-G4 | RUN ID: {self.identity['runId']}")
        path = self.run / "closeout.json"
        if path.exists() or path.is_symlink():
            print("Service-restored approval already exists for this run. P4-G4 cannot overwrite or repeat it.")
            print("Existing approval and recovery metrics are unchanged; continue the separately approved failback workflow instead.")
            raise ValueError("Immutable closeout already exists; no overwrite.")
        records, contents, times = self.load()
        print(self.summary(times, color=True))
        approver = self.ask("Approver name")
        role = self.ask("Approver role/title")
        now = utc_now()
        entered = input(question_prompt(f"Actual T10 UTC [{now.isoformat().replace('+00:00', 'Z')}]: ")).strip()
        t10 = timestamp(entered) if entered else now
        if t10 < times[3] or t10 > utc_now() + timedelta(seconds=60):
            raise ValueError("T10 must be at/after T9 and no more than 60 seconds in the future.")
        restrictions = input(question_prompt("Remaining restrictions or risks [Enter if none]: ")).strip() or "none"
        text(restrictions)
        print("\nSAVED EVIDENCE REFERENCES")
        print("  T0 logs:", records["incident.json"]["t0EvidenceRef"])
        print("  T8 health logs:", records["app-health.json"]["evidenceRef"])
        print("  T9 transaction ID:", records["app-e2e.json"]["transactionRef"])
        reviewed = input(token_prompt("Type ", "DECLARE-RESTORED", " if these references were reviewed, or EDIT to correct them: ")).strip()
        if reviewed == "DECLARE-RESTORED":
            t0_ref = records["incident.json"]["t0EvidenceRef"]
            t8_ref = records["app-health.json"]["evidenceRef"]
            t9_ref = records["app-e2e.json"]["transactionRef"]
        elif reviewed == "EDIT":
            t0_ref = self.ask("Corrected T0 monitor/app log reference")
            t8_ref = self.ask("Corrected T8 app health-check log reference")
            t9_ref = self.ask("Corrected T9 transaction/readback ID (no business payload)")
            if input(token_prompt("Type ", "DECLARE-RESTORED", " to attest the corrected references and approve T10: ")).strip() != "DECLARE-RESTORED":
                raise ValueError("Declaration not approved.")
        else:
            raise ValueError("Type DECLARE-RESTORED to approve or EDIT to correct references.")
        _, fresh, _ = self.load()
        if fresh != contents:
            raise ValueError("Evidence changed during declaration; review again.")
        result = dict(self.identity, environment=self.environment, status="service-restored",
                      approver=approver, role=role, t10At=t10.isoformat(),
                      t0EvidenceRef=t0_ref, t8EvidenceRef=t8_ref,
                      t9Ref=records["app-e2e.json"]["transactionRef"], t9EvidenceRef=t9_ref,
                      originalT0EvidenceRef=records["incident.json"]["t0EvidenceRef"],
                      originalT8EvidenceRef=records["app-health.json"]["evidenceRef"],
                      reviewed=True, restrictions=restrictions, recordedAt=utc_now().isoformat(),
                      recoveryMetrics=self.recovery_metrics(times),
                      sourceHashes={name: digest(content) for name, content in contents.items()},
                      limitations=LIMITS)
        exclusive_write(path, encoded(result))
        print(f"P4-G4 recorded: {path}")
        return result

    def package(self):
        receipt_path = self.run / "evidence-package.json"
        if receipt_path.exists() or receipt_path.is_symlink():
            raise ValueError("Immutable package receipt already exists; no overwrite.")
        records, contents, times = self.load()
        contents["closeout.json"] = read_regular(self.run / "closeout.json")
        closed = decode(contents["closeout.json"])
        self.identify(closed)
        saved_metrics = closed.get("recoveryMetrics")
        if saved_metrics is not None and not isinstance(saved_metrics, dict):
            raise ValueError("Saved recovery metrics must be an object.")
        self.rto_target_minutes = 30.0 if saved_metrics is None else saved_metrics.get("rtoTargetMinutes")
        if (isinstance(self.rto_target_minutes, bool)
                or not isinstance(self.rto_target_minutes, (int, float))
                or not math.isfinite(self.rto_target_minutes) or self.rto_target_minutes <= 0):
            raise ValueError("Saved RTO target must be a positive finite number.")
        if saved_metrics is not None and saved_metrics != self.recovery_metrics(times):
            raise ValueError("Saved recovery metrics do not match the approved evidence.")
        if closed.get("status") != "service-restored" or closed.get("reviewed") is not True:
            raise ValueError("Reviewed service-restored closeout is required.")
        for key in ("approver", "role", "t0EvidenceRef", "t8EvidenceRef", "t9EvidenceRef", "restrictions"):
            text(closed.get(key))
        if "approvalRef" in closed:
            text(closed["approvalRef"])
        if closed.get("t9Ref") != records["app-e2e.json"]["transactionRef"]:
            raise ValueError("Closeout T9 reference mismatch.")
        if (closed.get("originalT0EvidenceRef") != records["incident.json"]["t0EvidenceRef"]
                or closed.get("originalT8EvidenceRef") != records["app-health.json"]["evidenceRef"]):
            raise ValueError("Closeout original evidence references mismatch.")
        recorded = timestamp(closed.get("recordedAt"))
        t10 = timestamp(closed.get("t10At"))
        if (not times[3] <= t10 <= utc_now() + timedelta(seconds=60)
                or recorded > utc_now() + timedelta(seconds=60) or t10 > recorded + timedelta(seconds=60)):
            raise ValueError("Invalid closeout T10.")
        expected = {name: digest(content) for name, content in contents.items() if name != "closeout.json"}
        if closed.get("sourceHashes") != expected:
            raise ValueError("Linked evidence changed since declaration; no package created.")
        print(self.summary(times))
        print("T10:", t10.isoformat())
        owner = text(closed["approver"])
        destination = safe_path(self.root / "evidence/bb3-packages")
        if (destination == self.run or self.run in destination.parents
                or destination == self.ledger or destination in self.ledger.parents):
            raise ValueError("Package destination must be outside the live run/ledger ancestors.")
        if not git_ignored(self.root, destination / "check.json"):
            raise ValueError("Package destination must be Git-ignored.")
        _, fresh, _ = self.load()
        fresh["closeout.json"] = read_regular(self.run / "closeout.json")
        if fresh != contents:
            raise ValueError("Evidence changed during packaging.")
        contents.pop("app-deploy.log", None)
        destination.mkdir(mode=0o700, parents=True, exist_ok=True)
        safe_path(destination)
        name = self.identity["runId"] + "-" + utc_now().strftime("%Y%m%dT%H%M%S%fZ")
        final = destination / name
        staging = Path(tempfile.mkdtemp(prefix=".closeout-package-", dir=destination))
        reserved = False
        try:
            snapshot = staging / "snapshot"
            snapshot.mkdir(mode=0o700)
            for filename, content in contents.items():
                exclusive_write(snapshot / filename, content)
            omitted = sorted(set(OPTIONAL) - contents.keys())
            summary = (self.summary(times) + f"T10: {t10.isoformat()}\nEvidence owner: {owner}\n"
                       f"Restrictions: {closed['restrictions']}\n"
                       "Included: " + ", ".join(sorted(contents)) + "\n"
                       "Optional files omitted or absent: " + (", ".join(omitted) or "none") + "\n"
                       "Automatic local packaging; owner reused from closeout approver. "
                       "Deployment logs omitted; no automatic log review is claimed.\n"
                       "Omitted: all non-allowlisted files and directories, configs, secrets, raw baselines, "
                       "and external reference targets. References are not automatically copied.\n"
                       "Manifest covers copied files and summary.md, not manifest.json itself. "
                       "Source hashes describe this frozen snapshot; later source edits do not alter it.\n"
                       + LIMITS + "\n")
            contents["summary.md"] = summary.encode()
            exclusive_write(snapshot / "summary.md", contents["summary.md"])
            hashes = {filename: digest(content) for filename, content in contents.items()}
            for filename, expected_hash in hashes.items():
                if digest(read_regular(snapshot / filename)) != expected_hash:
                    raise ValueError("Snapshot hash verification failed.")
            exclusive_write(snapshot / "manifest.json", encoded(dict(algorithm="sha256", files=hashes,
                            excludes=["manifest.json"], sourceHashes=closed["sourceHashes"])))
            archive_path = staging / "evidence.tar.gz"
            with tarfile.open(archive_path, "x:gz") as archive:
                for source in sorted(snapshot.iterdir()):
                    read_regular(source)
                    archive.add(source, arcname="snapshot/" + source.name, recursive=False)
            os.chmod(archive_path, 0o600)
            with tarfile.open(archive_path, "r:gz") as archive:
                members = archive.getmembers()
                expected_names = {"snapshot/" + filename for filename in (*hashes, "manifest.json")}
                if {member.name for member in members} != expected_names or len(members) != len(expected_names):
                    raise ValueError("Archive inventory verification failed.")
                for member in members:
                    if not member.isfile():
                        raise ValueError("Archive contains a non-file entry.")
                    stream = archive.extractfile(member)
                    if stream is None:
                        raise ValueError("Missing archive file.")
                    with stream:
                        if digest(stream.read()) != digest(read_regular(snapshot / Path(member.name).name)):
                            raise ValueError("Archive hash verification failed.")
            archive_hash = digest(read_regular(archive_path))
            exclusive_write(staging / "evidence.tar.gz.sha256", (archive_hash + "  evidence.tar.gz\n").encode())
            final.mkdir(mode=0o700)
            reserved = True
            os.replace(staging, final)
            receipt = dict(self.identity, environment=self.environment, status="local-packaged",
                           evidenceOwner=owner, location=str(final), archive=str(final / "evidence.tar.gz"),
                           archiveSha256=archive_hash, recordedAt=utc_now().isoformat(),
                           packagingMode="automatic-local", deploymentLogIncluded=False,
                           uploaded=False, limitations=LIMITS)
            exclusive_write(receipt_path, encoded(receipt))
        except BaseException:
            shutil.rmtree(staging, ignore_errors=True)
            if reserved:
                shutil.rmtree(final)
            raise
        print("Local package:", final)
        print("Local evidence package only; not uploaded. See snapshot/summary.md for limitations.")
        return receipt


def main():
    parser = argparse.ArgumentParser(description=LIMITS)
    parser.add_argument("command", choices=("declare", "package", "capture-snapshot"))
    for name in ("root", "ledger", "run-id", "account", "region", "environment"):
        parser.add_argument("--" + name, required=True)
    for name in ("snapshot-json", "snapshot-id", "source-db", "restored-primary"):
        parser.add_argument("--" + name)
    args = parser.parse_args()
    if args.command == "capture-snapshot" and any(value is None for value in (
            args.snapshot_json, args.snapshot_id, args.source_db, args.restored_primary)):
        parser.error("capture-snapshot requires snapshot JSON, snapshot ID, source DB and restore target")
    try:
        if args.command == "declare" and (not sys.stdin.isatty() or not sys.stdout.isatty()):
            raise ValueError("A real interactive terminal is required.")
        os.umask(0o077)
        workflow = Closeout(args.root, args.ledger, args.run_id, args.account, args.region, args.environment)
        if not git_ignored(workflow.root, workflow.run / "closeout.json"):
            raise ValueError("Ledger must be Git-ignored.")
        if args.command == "capture-snapshot":
            workflow.capture_snapshot(decode(args.snapshot_json), args.source_db,
                                      args.restored_primary, args.snapshot_id)
        else:
            getattr(workflow, args.command)()
        return 0
    except (OSError, ValueError, EOFError, KeyboardInterrupt):
        print("Closeout refused or interrupted; inspect journal prerequisites/approval and immutable outputs. "
              "No AWS verification or upload was performed.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())