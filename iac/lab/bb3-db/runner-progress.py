import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import importlib.util


RECOVERY = ["P0-S01", "P0-S02", "P0-S03", "P1-S01-1", "P1-S01-2", "P2-S00",
            "P2-S01", "P2-S02", "P2-S03", "P2-S04", "P2-S05", "P2-S06",
            "P2-S07", "P2-S08", "P2-S09", "P3-S01", "P3-S02", "P3-S03",
            "P4-S01", "P4-S02", "P4-G4", "P5"]
FAILBACK = ["preview", "fence", "endpoints", "release", "deployment", "health", "signoff"]
JOURNALS = ("cutover.json", "network-fence.json", "incident.json", "fence.json",
            "app-deploy.json", "app-health.json", "app-e2e.json", "closeout.json", "evidence-package.json",
            "failback-network-fence.json", "failback-fence.json", "failback.json",
            "failback-app-deploy.json", "failback-app-health.json", "failback-app-e2e.json", "failback-signoff.json")
WRITES = {
    "P0-S03": {"network-fence.json"}, "P1-S01-2": {"incident.json"},
    "P3-S01": {"fence.json"}, "P3-S02": {"cutover.json"}, "P3-S03": {"app-deploy.json"},
    "P4-S01": {"app-health.json"}, "P4-S02": {"app-e2e.json"},
    "P4-G4": {"closeout.json"}, "P5": {"evidence-package.json"},
    "fence": {"failback-network-fence.json", "failback-fence.json"},
    "endpoints": {"failback.json"}, "release": {"network-fence.json"},
    "deployment": {"failback-app-deploy.json"}, "health": {"failback-app-health.json"},
    "signoff": {"failback-app-e2e.json", "failback-signoff.json"},
}


def helper(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), Path(__file__).with_name(name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def regular_json(path):
    if any(parent.is_symlink() for parent in (path, *path.parents)) or not path.is_file():
        raise ValueError("Progress evidence must be regular files without symlinks.")
    return helper("closeout").decode(helper("closeout").read_regular(path))


def matching(record, identity, **expected):
    return isinstance(record, dict) and all(record.get(key) == value
                                            for key, value in {**identity, **expected}.items())


def failback_next(records, identity):
    cutover = records.get("cutover.json")
    if not matching(cutover, identity, status="complete") or cutover.get("operation", "cutover") != "cutover":
        raise ValueError("A matching completed cutover is required; no run is selected automatically.")
    for key in ("db", "source_db", "oldHost", "newHost"):
        if not isinstance(cutover.get(key), str) or not cutover[key].strip():
            raise ValueError("The saved cutover is incomplete.")
    active = dict(activePrimary=cutover["db"], activeReplica=cutover.get("replica") or "")
    returned = dict(returnPrimary=cutover["source_db"], returnReplica=cutover.get("source_replica") or "")
    network = records.get("failback-network-fence.json")
    fence = records.get("failback-fence.json")
    if not (matching(network, identity, mode="failback", status="attached", **active)
            and matching(fence, identity, mode="failback", status="owner-confirmed",
                         fenceVerified=True, existingSessionsClosed=True, **active, **returned)
            and isinstance(fence.get("appOwner"), str) and fence["appOwner"].strip()):
        return "fence"
    if not matching(records.get("failback.json"), identity, operation="failback", status="complete",
                    source_db=cutover["db"], source_replica=cutover.get("replica") or "",
                    db=cutover["source_db"], replica=cutover.get("source_replica") or ""):
        return "endpoints"
    if not matching(records.get("network-fence.json"), identity, mode="cutover", status="released",
                    activePrimary=cutover["source_db"], activeReplica=cutover.get("source_replica") or ""):
        return "release"
    owner = fence["appOwner"]
    endpoints = dict(primaryHost=cutover["oldHost"], replicaHost=cutover.get("oldReplicaHost") or "")
    common = dict(operation="failback", status="owner-confirmed", appOwner=owner, **endpoints)
    deployment = records.get("failback-app-deploy.json")
    if not (matching(deployment, identity, mode="manual", servicesConverged=True, **common)
            and deployment.get("evidenceRef")):
        return "deployment"
    health = records.get("failback-app-health.json")
    if not (matching(health, identity, healthVerified=True, **common) and health.get("evidenceRef")):
        return "health"
    return "signoff"


def read_records(directory):
    records = {}
    if any(parent.is_symlink() for parent in (directory, *directory.parents)):
        raise ValueError("Progress paths must not contain symlinks.")
    if not directory.exists():
        return records
    for filename in JOURNALS:
        path = directory / filename
        if path.exists() or path.is_symlink():
            records[path.name] = regular_json(path)
    return records


def state_path(ledger, context, mode):
    if mode == "failback":
        return ledger / context["runId"] / "runner-progress.json"
    return ledger / (".runner-recovery-" + context["environment"] + ".json")


def evidence_hashes(ledger, context):
    if not context.get("runId"):
        return {}
    directory = ledger / context["runId"]
    records = read_records(directory)
    return {name: hashlib.sha256(helper("closeout").read_regular(directory / name)).hexdigest()
            for name in records}


def verify_package(record, identity, root):
    if not matching(record, identity, status="local-packaged", uploaded=False):
        raise ValueError("Invalid local evidence package receipt.")
    package = Path(record["location"])
    destination = root / "evidence/bb3-packages"
    if package.parent != destination or not package.name.startswith(identity["runId"] + "-"):
        raise ValueError("Package receipt points outside this run's evidence directory.")
    closeout = helper("closeout")
    archive = package / "evidence.tar.gz"
    if closeout.digest(closeout.read_regular(archive)) != record.get("archiveSha256"):
        raise ValueError("Package archive hash mismatch.")
    snapshot = package / "snapshot"
    manifest = regular_json(snapshot / "manifest.json")
    for name, digest in manifest["files"].items():
        if Path(name).name != name or closeout.digest(closeout.read_regular(snapshot / name)) != digest:
            raise ValueError("Package manifest hash mismatch.")


def recovery_next(records, state, context, inventory=None):
    identity = {key: context[key] for key in ("runId", "account", "region")}
    for name, record in records.items():
        if name.startswith("failback"):
            continue
        if record.get("runId") != context["runId"]:
            raise ValueError("Recovery journal run ID mismatch: " + name)
        for key in ("account", "region"):
            if key in record and record[key] != context[key]:
                raise ValueError("Recovery journal identity mismatch: " + name)
    if "evidence-package.json" in records:
        verify_package(records["evidence-package.json"], identity, Path(context["root"]))
        return None
    if "closeout.json" in records or "app-e2e.json" in records:
        closeout = helper("closeout")
        workflow = closeout.Closeout(context["root"], context["ledger"], context["runId"],
                                    context["account"], context["region"], context["environment"])
        _, contents, _ = workflow.load()
        if "closeout.json" in records:
            closed = records["closeout.json"]
            if not matching(closed, identity, status="service-restored", reviewed=True):
                raise ValueError("Invalid T10 closeout; inspect it before continuing.")
            if closed.get("sourceHashes") != {name: closeout.digest(content) for name, content in contents.items()}:
                raise ValueError("Evidence changed since T10; do not repeat approval or overwrite it.")
            return "P5"
        return "P4-G4"
    cutover = records.get("cutover.json")
    if cutover:
        if not matching(cutover, identity, status="complete") or cutover.get("operation", "cutover") != "cutover":
            return "P3-S02"
        deployment = records.get("app-deploy.json")
        if not deployment:
            return "P3-S03"
        if not matching(deployment, {"runId": identity["runId"]}, status="owner-confirmed", servicesConverged=True):
            raise ValueError("Invalid deployment attestation; do not overwrite it.")
        health = records.get("app-health.json")
        if not health:
            return "P4-S01"
        if not matching(health, identity, status="owner-confirmed", connectivityVerified=True,
                        appOwner=deployment.get("appOwner")):
            raise ValueError("Invalid health attestation; do not overwrite it.")
        return "P4-S02"
    fence = records.get("fence.json")
    if fence:
        if not matching(fence, identity, mode="cutover", status="owner-confirmed",
                        fenceVerified=True, existingSessionsClosed=True):
            return "P3-S01"
        return "P3-S02"
    completed = state.get("completed", [])
    pending = state.get("pending")
    if pending in ("P2-S01", "P2-S05"):
        if inventory is None:
            return "probe"
        target = context["targetPrimary" if pending == "P2-S01" else "targetReplica"]
        matches = [record for record in inventory if record.get("DBInstanceIdentifier") == target]
        if not matches:
            return pending
        instance = matches[0]
        tags = {tag["Key"]: tag["Value"] for tag in instance.get("TagList", [])}
        if tags.get("dr-restore") != context["runId"] or instance.get("Engine") != "postgres":
            raise ValueError("Existing restore target is not proven to belong to this run; no resubmission.")
        if pending == "P2-S05" and instance.get("ReadReplicaSourceDBInstanceIdentifier", "").split(":")[-1] != context["targetPrimary"]:
            raise ValueError("Existing replica has the wrong source; no resubmission.")
        return "P2-S02" if pending == "P2-S01" else "P2-S06"
    if state:
        for step in RECOVERY:
            if step not in completed:
                return step
        raise ValueError("Checkpoint claims completion without final evidence; inspect the run.")
    incident = records.get("incident.json")
    if matching(incident, identity, status="declared", scenario="S3"):
        if inventory is None:
            return "probe"
        next_step = recovery_next({}, dict(pending="P2-S01"), context, inventory)
        return "P2-S00" if next_step == "P2-S01" else next_step
    network = records.get("network-fence.json")
    if network:
        if not matching(network, identity, mode="cutover", status="attached"):
            return "P0-S03"
        if context.get("t0At") and context.get("t0Ref"):
            helper("secret-endpoints").parse_utc_timestamp(context["t0At"], "Saved T0")
            return "P1-S01-2"
        return "P1-S01-1"
    return "P0-S01"


def plan(ledger, context, mode, inventory=None):
    run_id = context.get("runId", "")
    if run_id and not re.fullmatch(r"DR-[A-Za-z0-9_-]{1,120}", run_id):
        raise ValueError("Invalid saved explicit run ID.")
    records = read_records(ledger / run_id) if run_id else {}
    path = state_path(ledger, context, mode)
    state = regular_json(path) if path.exists() or path.is_symlink() else {}
    if state and state.get("context") != context:
        changed = sorted(key for key in set(context) | set(state.get("context", {}))
                         if context.get(key) != state.get("context", {}).get(key))
        raise ValueError("Saved runner scope/configuration differs (" + ", ".join(changed) + "); review it before resuming.")
    if state:
        current_hashes = evidence_hashes(ledger, context)
        allowed_changes = WRITES.get(state.get("pending"), set())
        for name, digest in state.get("evidenceHashes", {}).items():
            if name not in allowed_changes and current_hashes.get(name) != digest:
                raise ValueError("Completed evidence changed since checkpoint: " + name)
    if mode == "recovery" and any(name.startswith("failback-") or name == "failback.json" for name in records):
        return plan(ledger, context, "failback", inventory)
    identity = {key: context.get(key) for key in ("runId", "account", "region")}
    if mode == "failback":
        if "failback-signoff.json" in records:
            endpoints = helper("secret-endpoints")
            review = endpoints.failback_signoff_review(ledger, run_id, context["account"], context["region"])
            signed = records["failback-signoff.json"]
            if (signed.get("evidenceHashes") != review["evidenceHashes"] or
                    any(signed.get(key) != review[key] for key in
                        ("runId", "account", "region", "appOwner", "evidence", "primaryHost", "replicaHost")) or
                    signed.get("status") != "signed-off" or signed.get("operation") != "failback" or
                    signed.get("approval") != "SIGN-OFF-FAILBACK" or signed.get("evidenceReviewedByOwner") is not True):
                raise ValueError("Failback sign-off is invalid or changed; inspect before continuing.")
            next_step = None
        else:
            next_step = failback_next(records, identity) if records else "preview"
    else:
        next_step = recovery_next(records, state, context, inventory)
    return dict(mode=mode, runId=run_id, next=next_step, existing=bool(records or state),
                completed=state.get("completed", []), pending=state.get("pending"))


def checkpoint(ledger, context, mode, action, step):
    path = state_path(ledger, context, mode)
    if any(parent.is_symlink() for parent in (path, *path.parents)):
        raise ValueError("Runner checkpoint paths cannot contain symlinks.")
    state = regular_json(path) if path.exists() else {}
    if action == "start" and state and state.get("context") != context:
        raise ValueError("Configuration changed between actions; inspect before continuing.")
    if (action == "done" and state and state.get("context") != context and
            step not in ("P0-S01", "P0-S03", "P1-S01-1", "P1-S01-2")):
        raise ValueError("Configuration changed during the action; checkpoint not advanced.")
    if action == "reset":
        state = {}
    completed = state.get("completed", [])
    if action == "adopt":
        sequence = FAILBACK if mode == "failback" else RECOVERY
        completed = sequence[:sequence.index(step)]
    if action == "done" and step not in completed:
        completed.append(step)
    state = dict(context=context, completed=completed, pending=step if action == "start" else None,
                 evidenceHashes=evidence_hashes(ledger, context))
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".runner-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(state, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("plan", "start", "done", "reset", "adopt"))
    parser.add_argument("--context", required=True)
    parser.add_argument("--mode", choices=("recovery", "failback"), required=True)
    parser.add_argument("--step", default="")
    parser.add_argument("--inventory")
    args = parser.parse_args()
    try:
        context = json.loads(args.context)
        if context["environment"] not in ("dev", "uat"):
            raise ValueError("Only dev/uat runner checkpoints are supported.")
        ledger = Path(context["ledger"])
        if args.command == "plan":
            inventory = json.loads(args.inventory) if args.inventory is not None else None
            print(json.dumps(plan(ledger, context, args.mode, inventory)))
        else:
            checkpoint(ledger, context, args.mode, args.command, args.step)
    except (ValueError, OSError, KeyError) as error:
        print("Resume refused: " + str(error), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())