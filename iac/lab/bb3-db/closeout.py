import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
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
OPTIONAL = ("network-fence.json", "app-deploy.log", "run-report.md")
LIMITS = ("Partial local evidence only. Owner attestations are not independent validation. "
          "No live AWS verification or upload was performed. Baseline/raw API evidence is "
          "not bundled automatically and remains separate/pending. RPO is not independently "
          "measured. This is not full audit evidence or business certification.")


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
        return records, contents, (t0, t1, t8, t9)

    def summary(self, times, color=False):
        t0, t1, t8, t9 = times
        rto_minutes = (t8 - t0).total_seconds() / 60
        validation_minutes = (t9 - t8).total_seconds() / 60
        total_minutes = (t9 - t0).total_seconds() / 60
        use_color = color and sys.stdout.isatty() and "NO_COLOR" not in os.environ
        cyan = "\033[1;36m" if use_color else ""
        green = "\033[1;32m" if use_color else ""
        red = "\033[1;31m" if use_color else ""
        reset = "\033[0m" if use_color else ""
        result_color = green if rto_minutes <= 30 else red
        result = "PASS" if rto_minutes <= 30 else "MISS"
        stamp = lambda value: value.isoformat().replace("+00:00", "Z")
        lines = [
            "=" * 76,
            "STAGE: P4-G4 | Service Restored Approval",
            f"RUN ID: {self.identity['runId']}",
            "=" * 76,
            "",
            "TIMELINE & RTO METRICS",
            f"  T0 (Impact): {cyan}{stamp(t0)}{reset}",
            f"  T1 (Declared): {cyan}{stamp(t1)}{reset}  (T1-T0: {(t1-t0).total_seconds()/60:.2f} min)",
            f"  T8 (Health): {cyan}{stamp(t8)}{reset}  (T8-T0: {rto_minutes:.2f} min) "
            f"[{result_color}{result}{reset} - Target: 30 min]",
            f"  T9 (Business): {cyan}{stamp(t9)}{reset}  (T9-T8: {validation_minutes:.2f} min)",
            f"  Total through T9: {total_minutes:.2f} min",
            "  RPO: Not independently measured",
        ]
        return "\n".join(lines) + "\n"

    def ask(self, prompt):
        return text(input(question_prompt(prompt + " (no secrets): ")))

    def declare(self):
        path = self.run / "closeout.json"
        if path.exists() or path.is_symlink():
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
    parser.add_argument("command", choices=("declare", "package"))
    for name in ("root", "ledger", "run-id", "account", "region", "environment"):
        parser.add_argument("--" + name, required=True)
    args = parser.parse_args()
    try:
        if args.command == "declare" and (not sys.stdin.isatty() or not sys.stdout.isatty()):
            raise ValueError("A real interactive terminal is required.")
        os.umask(0o077)
        workflow = Closeout(args.root, args.ledger, args.run_id, args.account, args.region, args.environment)
        if not git_ignored(workflow.root, workflow.run / "closeout.json"):
            raise ValueError("Ledger must be Git-ignored.")
        getattr(workflow, args.command)()
        return 0
    except (OSError, ValueError, EOFError, KeyboardInterrupt):
        print("Closeout refused or interrupted; inspect journal prerequisites/approval and immutable outputs. "
              "No AWS verification or upload was performed.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())