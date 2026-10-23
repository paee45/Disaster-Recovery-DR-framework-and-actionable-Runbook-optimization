import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import uuid
from datetime import datetime, timezone


class AwsCliClient:
    def __init__(self, profile, region, service):
        self.profile = profile
        self.region = region
        self.service = service

    def call(self, action, request):
        arguments = ["aws", "--profile", self.profile, "--region", self.region,
                     "--no-cli-pager", self.service, action]
        secret_input = None
        for name, value in request.items():
            kebab_name = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1-\2", name)
            kebab_name = re.sub(r"([a-z0-9])([A-Z])", r"\1-\2", kebab_name)
            option = "--" + kebab_name.lower()
            if name == "SecretString":
                arguments.extend((option, "file:///dev/stdin"))
                secret_input = value
            elif isinstance(value, list):
                arguments.append(option)
                arguments.extend(str(item) for item in value)
            else:
                arguments.extend((option, str(value)))
        arguments.extend(("--output", "json"))
        result = subprocess.run(arguments, input=secret_input, capture_output=True,
                                text=True, timeout=90)
        if result.returncode:
            raise RuntimeError(f"AWS {self.service} {action} failed; response withheld to protect credentials.")
        try:
            return json.loads(result.stdout)
        except (TypeError, ValueError):
            raise RuntimeError("AWS returned an invalid JSON response; content withheld.") from None

    def describe_db_instances(self, **request):
        return self.call("describe-db-instances", request)

    def describe_secret(self, **request):
        return self.call("describe-secret", request)

    def get_secret_value(self, **request):
        return self.call("get-secret-value", request)

    def put_secret_value(self, **request):
        return self.call("put-secret-value", request)

    def update_secret_version_stage(self, **request):
        return self.call("update-secret-version-stage", request)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON key.")
        result[key] = value
    return result


def record_path(directory, run_id, operation):
    if not re.fullmatch(r"DR-[A-Za-z0-9_-]{1,120}", run_id):
        raise ValueError("Use a DR- run ID containing only letters, digits, hyphens and underscores.")
    if operation not in ("cutover", "failback"):
        raise ValueError("Invalid endpoint operation.")
    return Path(directory) / run_id / (operation + ".json")


def save_record(path, record, exclusive=False):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if exclusive:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as stream:
            json.dump(record, stream, allow_nan=False)
            stream.flush()
            os.fsync(stream.fileno())
    else:
        with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as stream:
            temporary = Path(stream.name)
            try:
                json.dump(record, stream, allow_nan=False)
                stream.flush()
                os.fsync(stream.fileno())
                os.replace(temporary, path)
            finally:
                temporary.unlink(missing_ok=True)
    descriptor = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def verified_fence_record(path, run_id, account, region, active_primary,
                          active_replica, return_primary, return_replica):
    try:
        record = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return False
    matches = (
        record.get("runId") == run_id and record.get("account") == account and
        record.get("region") == region and record.get("status") == "owner-confirmed" and
        record.get("activePrimary") == active_primary and
        (record.get("activeReplica") or "") == active_replica and
        record.get("returnPrimary") == return_primary and
        (record.get("returnReplica") or "") == return_replica and
        record.get("fenceVerified") is True
    )
    stopped = record.get("fenceMethod") == "rds-stopped" and record.get("rdsStopConfirmed") is True
    quarantined = (
        record.get("fenceMethod") == "security-group-no-ingress" and
        record.get("existingSessionsClosed") is True and
        bool(record.get("quarantineSecurityGroup"))
    )
    return matches and (stopped or quarantined)


def load_cutover(directory, selection, account, region):
    if selection == "latest":
        candidates = []
        for path in Path(directory).glob("DR-*/cutover.json"):
            record = json.loads(path.read_text())
            if record.get("status") == "complete" and record.get("account") == account and record.get("region") == region:
                if not (path.parent / "failback.json").exists():
                    candidates.append(record)
        if not candidates:
            raise ValueError("No completed, unfailed-back cutover found for this account/region.")
        return max(candidates, key=lambda record: record["createdAt"])
    path = record_path(directory, selection, "cutover")
    record = json.loads(path.read_text())
    if record.get("status") != "complete" or record.get("account") != account or record.get("region") != region:
        raise ValueError("Saved cutover is incomplete or belongs to a different account/region.")
    return record


def record_app_deployment(directory, run_id, account, region, owner, evidence_ref):
    cutover = load_cutover(directory, run_id, account, region)
    if not owner.strip() or not evidence_ref.strip():
        raise ValueError("App owner and deployment log evidence reference are required.")
    path = Path(directory) / run_id / "app-deploy.json"
    if path.exists():
        raise ValueError("App deployment confirmation already exists for this DR run.")
    result = {
        "runId": run_id, "secretName": cutover["secretName"],
        "mode": "manual", "status": "owner-confirmed",
        "appOwner": owner.strip(),
        "evidenceRef": evidence_ref.strip(),
        "primaryHost": cutover["newHost"], "replicaHost": cutover["newReplicaHost"],
        "servicesConverged": True,
        "recordedAt": datetime.now(timezone.utc).isoformat(),
    }
    save_record(path, result, exclusive=True)
    return result


def record_app_health(directory, run_id, account, region, owner, evidence_ref, t0_at):
    cutover = load_cutover(directory, run_id, account, region)
    deployment_path = Path(directory) / run_id / "app-deploy.json"
    if not deployment_path.exists():
        raise ValueError("A completed app deployment attestation is required before T8.")
    deployment = json.loads(deployment_path.read_text())
    if (deployment.get("status") != "owner-confirmed" or deployment.get("appOwner") != owner.strip()
            or not deployment.get("servicesConverged")):
        raise ValueError("A matching completed app deployment attestation is required before T8.")
    if not evidence_ref.strip():
        raise ValueError("A health-check evidence reference is required.")
    try:
        t0 = datetime.fromisoformat(t0_at.replace("Z", "+00:00"))
    except (TypeError, ValueError):
        raise ValueError("T0 must be a UTC ISO-8601 timestamp.") from None
    if t0.tzinfo is None or t0.utcoffset() != timezone.utc.utcoffset(t0):
        raise ValueError("T0 must include a UTC timezone.")
    path = Path(directory) / run_id / "app-health.json"
    if path.exists():
        raise ValueError("T8 connectivity confirmation already exists for this DR run.")
    result = {
        "runId": run_id, "status": "owner-confirmed", "account": account, "region": region,
        "appOwner": owner.strip(), "connectivityVerified": True,
        "primaryHost": cutover["newHost"], "replicaHost": cutover["newReplicaHost"],
        "evidenceRef": evidence_ref.strip(), "t0At": t0.isoformat(), "t8At": datetime.now(timezone.utc).isoformat(),
        "serviceRtoMinutes": round((datetime.now(timezone.utc) - t0).total_seconds() / 60, 2),
    }
    save_record(path, result, exclusive=True)
    return result


def record_app_e2e(directory, run_id, account, region, owner, transaction_ref):
    health_path = Path(directory) / run_id / "app-health.json"
    if not health_path.exists():
        raise ValueError("A T8 app-connectivity confirmation is required before T9.")
    health = json.loads(health_path.read_text())
    if (health.get("runId") != run_id or health.get("account") != account or
            health.get("region") != region or health.get("status") != "owner-confirmed" or
            health.get("appOwner") != owner.strip() or not health.get("connectivityVerified")):
        raise ValueError("A matching T8 app-connectivity confirmation is required before T9.")
    if not transaction_ref.strip():
        raise ValueError("A successful transaction/readback reference is required.")
    path = Path(directory) / run_id / "app-e2e.json"
    if path.exists():
        raise ValueError("T9 transaction confirmation already exists for this DR run.")
    t8_at = datetime.fromisoformat(health["t8At"])
    t9_at = datetime.now(timezone.utc)
    result = {
        "runId": run_id, "status": "owner-confirmed", "account": account, "region": region,
        "appOwner": owner.strip(), "transactionRef": transaction_ref.strip(),
        "transactionSucceeded": True, "t8At": health["t8At"], "t9At": t9_at.isoformat(),
        "businessValidationMinutes": round((t9_at - t8_at).total_seconds() / 60, 2),
        "serviceRtoMinutes": health.get("serviceRtoMinutes"), "t0At": health.get("t0At"),
    }
    save_record(path, result, exclusive=True)
    return result


def load_failback_context(directory, run_id, account, region):
    if not re.fullmatch(r"DR-[A-Za-z0-9_-]{1,120}", run_id):
        raise ValueError("A valid explicit DR- run ID is required for failback app evidence.")
    run_dir = Path(directory) / run_id
    if not (run_dir / "cutover.json").is_file():
        raise ValueError("A completed matching cutover is required for this failback run.")
    cutover = load_cutover(directory, run_id, account, region)
    if cutover.get("runId") != run_id:
        raise ValueError("Saved cutover run ID does not match the selected failback run.")
    failback_path = run_dir / "failback.json"
    try:
        failback = json.loads(failback_path.read_text())
    except (OSError, ValueError):
        raise ValueError("A completed matching endpoint failback is required.") from None
    if (failback.get("runId") != run_id or failback.get("operation") != "failback" or
            failback.get("status") != "complete" or failback.get("account") != account or
            failback.get("region") != region or failback.get("source_db") != cutover["db"] or
            (failback.get("source_replica") or "") != (cutover.get("replica") or "") or
            failback.get("db") != cutover["source_db"] or
            (failback.get("replica") or "") != (cutover.get("source_replica") or "")):
        raise ValueError("A completed matching endpoint failback is required.")

    journals = (
        ("network-fence.json", {
            "mode": "cutover", "status": "released",
            "activePrimary": cutover["source_db"],
            "activeReplica": cutover.get("source_replica") or "",
        }),
        ("failback-network-fence.json", {
            "mode": "failback", "status": "attached",
            "activePrimary": cutover["db"],
            "activeReplica": cutover.get("replica") or "",
        }),
        ("failback-fence.json", {
            "mode": "failback", "status": "owner-confirmed", "activePrimary": cutover["db"],
            "activeReplica": cutover.get("replica") or "",
            "returnPrimary": cutover["source_db"],
            "returnReplica": cutover.get("source_replica") or "",
        }),
    )
    records = {}
    for filename, expected in journals:
        try:
            record = json.loads((run_dir / filename).read_text())
        except (OSError, ValueError):
            raise ValueError(f"Required failback journal is missing or invalid: {filename}.") from None
        if (record.get("runId") != run_id or record.get("account") != account or
                record.get("region") != region or any(
                    (record.get(key) or "") != (value or "") for key, value in expected.items()
                )):
            raise ValueError(f"Required failback journal does not match: {filename}.")
        if filename == "failback-fence.json" and (
                record.get("fenceVerified") is not True or
                record.get("existingSessionsClosed") is not True or
                not isinstance(record.get("appOwner"), str) or not record["appOwner"].strip()):
            raise ValueError("Confirmed failback isolation and session closure are required.")
        records[filename] = record

    if not cutover.get("oldHost") or not cutover.get("oldReplicaHost"):
        raise ValueError("Saved original endpoint pair is incomplete.")
    return {
        "cutover": cutover,
        "failbackFence": records["failback-fence.json"],
        "account": account,
        "region": region,
        "primaryHost": cutover["oldHost"],
        "replicaHost": cutover["oldReplicaHost"],
    }


def record_failback_app_deployment(directory, run_id, account, region, owner, evidence_ref):
    context = load_failback_context(directory, run_id, account, region)
    if not owner.strip() or not evidence_ref.strip():
        raise ValueError("App owner and sanitized failback deployment log reference are required.")
    expected_evidence = f"evidence/bb3-secret-endpoints/{run_id}/failback-app-deploy.log"
    if evidence_ref.strip() != expected_evidence:
        raise ValueError("Failback deployment evidence must reference the run's failback-app-deploy.log.")
    if owner.strip() != context["failbackFence"]["appOwner"].strip():
        raise ValueError("Failback app owner must match the confirmed failback fence owner.")
    path = Path(directory) / run_id / "failback-app-deploy.json"
    if path.exists():
        raise ValueError("Failback app deployment confirmation already exists for this run.")
    result = {
        "runId": run_id, "operation": "failback", "status": "owner-confirmed",
        "account": account, "region": region, "mode": "manual", "appOwner": owner.strip(),
        "evidenceRef": evidence_ref.strip(), "primaryHost": context["primaryHost"],
        "replicaHost": context["replicaHost"], "servicesConverged": True,
        "recordedAt": datetime.now(timezone.utc).isoformat(),
    }
    save_record(path, result, exclusive=True)
    return result


def parse_utc_timestamp(value, label):
    try:
        timestamp = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (AttributeError, TypeError, ValueError):
        raise ValueError(f"{label} must be a UTC ISO-8601 timestamp.") from None
    if timestamp.tzinfo is None or timestamp.utcoffset() != timezone.utc.utcoffset(timestamp):
        raise ValueError(f"{label} must be a UTC ISO-8601 timestamp.")
    return timestamp


def matching_failback_deployment(path, context, run_id, account, region, owner):
    try:
        deployment = json.loads(path.read_text())
    except (OSError, ValueError):
        raise ValueError("A matching failback app deployment attestation is required.") from None
    if (deployment.get("runId") != run_id or deployment.get("operation") != "failback" or
            deployment.get("account") != account or deployment.get("region") != region or
            deployment.get("status") != "owner-confirmed" or deployment.get("mode") != "manual" or
            deployment.get("appOwner") != owner.strip() or deployment.get("servicesConverged") is not True or
            deployment.get("primaryHost") != context["primaryHost"] or
            deployment.get("replicaHost") != context["replicaHost"]):
        raise ValueError("A matching failback app deployment attestation is required.")
    return deployment


def record_failback_app_health(directory, run_id, account, region, owner, evidence_ref, health_at):
    context = load_failback_context(directory, run_id, account, region)
    if not owner.strip() or not evidence_ref.strip():
        raise ValueError("App owner and health-check evidence reference are required.")
    run_dir = Path(directory) / run_id
    matching_failback_deployment(run_dir / "failback-app-deploy.json", context,
                                 run_id, account, region, owner)
    path = run_dir / "failback-app-health.json"
    if path.exists():
        raise ValueError("Failback app health confirmation already exists for this run.")
    result = {
        "runId": run_id, "operation": "failback", "status": "owner-confirmed",
        "account": account, "region": region, "appOwner": owner.strip(),
        "healthVerified": True, "primaryHost": context["primaryHost"],
        "replicaHost": context["replicaHost"], "evidenceRef": evidence_ref.strip(),
        "healthCheckAt": parse_utc_timestamp(health_at, "Health-check time").isoformat(),
        "recordedAt": datetime.now(timezone.utc).isoformat(),
    }
    save_record(path, result, exclusive=True)
    return result


def record_failback_app_e2e(directory, run_id, account, region, owner, transaction_ref, transaction_at):
    context = load_failback_context(directory, run_id, account, region)
    if not owner.strip() or not transaction_ref.strip():
        raise ValueError("App owner and non-secret transaction reference are required.")
    run_dir = Path(directory) / run_id
    matching_failback_deployment(run_dir / "failback-app-deploy.json", context,
                                 run_id, account, region, owner)
    health_path = run_dir / "failback-app-health.json"
    try:
        health = json.loads(health_path.read_text())
    except (OSError, ValueError):
        raise ValueError("A matching failback app health confirmation is required.") from None
    if (health.get("runId") != run_id or health.get("operation") != "failback" or
            health.get("account") != account or health.get("region") != region or
            health.get("status") != "owner-confirmed" or health.get("appOwner") != owner.strip() or
            health.get("healthVerified") is not True or
            health.get("primaryHost") != context["primaryHost"] or
            health.get("replicaHost") != context["replicaHost"]):
        raise ValueError("A matching failback app health confirmation is required.")
    path = run_dir / "failback-app-e2e.json"
    if path.exists():
        raise ValueError("Failback business transaction confirmation already exists for this run.")
    result = {
        "runId": run_id, "operation": "failback", "status": "owner-confirmed",
        "account": account, "region": region, "appOwner": owner.strip(),
        "transactionRef": transaction_ref.strip(), "businessTransactionVerified": True,
        "primaryHost": context["primaryHost"], "replicaHost": context["replicaHost"],
        "transactionAt": parse_utc_timestamp(transaction_at, "Transaction time").isoformat(),
        "recordedAt": datetime.now(timezone.utc).isoformat(),
    }
    save_record(path, result, exclusive=True)
    return result


def failback_signoff_review(directory, run_id, account, region):
    context = load_failback_context(directory, run_id, account, region)
    owner = context["failbackFence"]["appOwner"].strip()
    run_dir = Path(directory) / run_id
    deployment = matching_failback_deployment(
        run_dir / "failback-app-deploy.json", context, run_id, account, region, owner)
    records = {"deployment": deployment}
    hashes = {}
    for label, filename, verified in (
            ("health", "failback-app-health.json", "healthVerified"),
            ("transaction", "failback-app-e2e.json", "businessTransactionVerified")):
        record = json.loads((run_dir / filename).read_text())
        if (any(record.get(key) != value for key, value in {
                "runId": run_id, "operation": "failback", "status": "owner-confirmed",
                "account": account, "region": region, "appOwner": owner,
                "primaryHost": context["primaryHost"], "replicaHost": context["replicaHost"],
        }.items()) or record.get(verified) is not True):
            raise ValueError(f"Matching failback {label} evidence is required for sign-off.")
        records[label] = record
    health_at = parse_utc_timestamp(records["health"]["healthCheckAt"], "Health-check time")
    transaction_at = parse_utc_timestamp(records["transaction"]["transactionAt"], "Transaction time")
    if transaction_at < health_at or transaction_at > datetime.now(timezone.utc):
        raise ValueError("Transaction time must follow health and must not be in the future.")
    for record, field in ((deployment, "evidenceRef"), (records["health"], "evidenceRef"),
                          (records["transaction"], "transactionRef")):
        if not isinstance(record.get(field), str) or not record[field].strip():
            raise ValueError("Deployment, health and transaction references are required.")
    for filename in ("cutover.json", "failback.json", "network-fence.json",
                     "failback-network-fence.json", "failback-fence.json",
                     "failback-app-deploy.json", "failback-app-health.json",
                     "failback-app-e2e.json", "failback-app-deploy.log"):
        path = run_dir / filename
        if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f"Nonempty regular evidence file required: {filename}.")
        hashes[filename] = hashlib.sha256(path.read_bytes()).hexdigest()
    return dict(runId=run_id, account=account, region=region, appOwner=owner,
                primaryHost=context["primaryHost"], replicaHost=context["replicaHost"],
                evidence=records, evidenceHashes=hashes)


def record_failback_signoff(directory, run_id, account, region, owner,
                            deployment_ref, health_ref, transaction_ref, approval):
    review = failback_signoff_review(directory, run_id, account, region)
    if owner.strip() != review["appOwner"] or approval != "SIGN-OFF-FAILBACK":
        raise ValueError("Matching app owner and explicit SIGN-OFF-FAILBACK approval are required.")
    references = dict(deployment=deployment_ref.strip(), health=health_ref.strip(),
                      transaction=transaction_ref.strip())
    if any(not value or value.lower() in ("y", "yes", "no", "none", "ok", "test", "placeholder")
           for value in references.values()):
        raise ValueError("Actual supporting deployment, health and transaction evidence references are required.")
    result = dict(review, operation="failback", status="signed-off",
                  supportingEvidence=references, signedOffAt=datetime.now(timezone.utc).isoformat(),
                  approval=approval, evidenceReviewedByOwner=True, cleanupAuthorized=False,
                  limitations="Owner attestation; external evidence is not independently verified.")
    save_record(Path(directory) / run_id / "failback-signoff.json", result, exclusive=True)
    return result


def retirement_context(directory, run_id, account, region):
    review = failback_signoff_review(directory, run_id, account, region)
    path = Path(directory) / run_id / "failback-signoff.json"
    if path.is_symlink() or not path.is_file():
        raise ValueError("A regular matching failback sign-off record is required for retirement.")
    signoff = json.loads(path.read_text())
    for key in ("runId", "account", "region", "appOwner", "evidence", "evidenceHashes",
                "primaryHost", "replicaHost"):
        if signoff.get(key) != review[key]:
            raise ValueError("Failback sign-off evidence changed; retirement is blocked.")
    if (signoff.get("status") != "signed-off" or signoff.get("operation") != "failback" or
            signoff.get("approval") != "SIGN-OFF-FAILBACK" or
            signoff.get("evidenceReviewedByOwner") is not True):
        raise ValueError("Explicit matching failback sign-off is required for retirement.")
    parse_utc_timestamp(signoff.get("signedOffAt"), "Sign-off time")
    references = signoff.get("supportingEvidence", {})
    if any(not isinstance(references.get(key), str) or not references[key].strip()
           for key in ("deployment", "health", "transaction")):
        raise ValueError("Supporting failback evidence references are required for retirement.")
    cutover = load_cutover(directory, run_id, account, region)
    identifiers = [cutover.get(key) for key in ("db", "replica", "source_db", "source_replica")]
    if (not all(isinstance(value, str) and re.fullmatch(r"[A-Za-z][A-Za-z0-9-]{0,62}", value)
                for value in identifiers) or len(set(identifiers)) != 4):
        raise ValueError("Retirement requires four distinct saved DB identifiers.")
    network = json.loads((Path(directory) / run_id / "failback-network-fence.json").read_text())
    quarantine = network.get("quarantineSecurityGroup", "")
    if not re.fullmatch(r"sg-[a-f0-9]+", quarantine):
        raise ValueError("A valid run-owned quarantine SG is required for retirement.")
    return dict(review, restoredPrimary=identifiers[0], restoredReplica=identifiers[1],
                originalPrimary=identifiers[2], originalReplica=identifiers[3],
                quarantineSecurityGroup=quarantine,
                signoffHash=hashlib.sha256(path.read_bytes()).hexdigest())


def bb3_update(event, rds, sm):
    operation = event.get("operation", "cutover")
    run_id = event.get("run_id", "")
    path = record_path(event["ledger_dir"], run_id, operation)
    saved = None
    if operation == "failback":
        saved = load_cutover(event["ledger_dir"], run_id, event["account"], event["region"])
        expected_ids = (saved["db"], saved["replica"], saved["source_db"], saved["source_replica"])
        if tuple(event.get(key) for key in ("source_db", "source_replica", "db", "replica")) != expected_ids:
            raise ValueError("Failback database IDs do not match the saved run.")
    if path.exists() and event.get("mode", "auto") != "manual":
        raise ValueError("This run already has an operation record. Inspect its status before retrying.")
    identifiers = [event.get(key) for key in ("source_db", "source_replica", "db", "replica")]
    if not all(identifiers) or len(set(identifiers)) != 4:
        raise ValueError("Four distinct database IDs are required.")
    databases = []
    for identifier in identifiers:
        instance = rds.describe_db_instances(DBInstanceIdentifier=identifier)["DBInstances"][0]
        if instance.get("Engine") != "postgres" or instance.get("DBInstanceStatus") != "available":
            raise ValueError("Every database must be available PostgreSQL.")
        databases.append(instance)
    source, source_replica, target, replica = databases
    for writer, reader in ((source, source_replica), (target, replica)):
        if writer.get("ReadReplicaSourceDBInstanceIdentifier"):
            raise ValueError("Primary must not be a replica.")
        if reader.get("ReadReplicaSourceDBInstanceIdentifier") != writer["DBInstanceIdentifier"]:
            raise ValueError("Replica does not belong to the expected primary.")
    metadata = sm.describe_secret(SecretId=event["secret_id"])
    if metadata["ARN"].split(":")[3:5] != [event["region"], event["account"]]:
        raise ValueError("Secret is outside the recorded sandbox account/region.")
    if saved and metadata["ARN"] != saved["secretArn"]:
        raise ValueError("Failback secret does not match the saved run.")
    if metadata.get("DeletedDate") or metadata.get("RotationEnabled") or metadata.get("OwningService"):
        raise ValueError("Deleted, rotating or service-managed secrets require a separate procedure.")
    if event.get("confirmed_secret") not in (metadata["Name"], metadata["ARN"]):
        raise ValueError("Confirm the exact secret name or full ARN before reading its value.")
    current = [version for version, stages in metadata["VersionIdsToStages"].items() if "AWSCURRENT" in stages]
    if len(current) != 1:
        raise ValueError("Expected exactly one AWSCURRENT version.")
    previous = current[0]
    if event.get("apply") == "true" and event.get("expected_version") != previous:
        raise ValueError("Secret version changed or preview version was not supplied. Preview again.")
    response = sm.get_secret_value(SecretId=metadata["ARN"], VersionId=previous, VersionStage="AWSCURRENT")
    try:
        secret = json.loads(response["SecretString"], object_pairs_hook=unique_object)
        json.dumps(secret, allow_nan=False)
    except (KeyError, TypeError, ValueError):
        raise ValueError("Secret must be a JSON string object.") from None
    if not isinstance(secret, dict):
        raise ValueError("Secret must be a JSON string object.")
    old_hosts = (source["Endpoint"]["Address"], source_replica["Endpoint"]["Address"])
    new_hosts = (target["Endpoint"]["Address"], replica["Endpoint"]["Address"])
    if saved and (old_hosts + new_hosts) != (
            saved["newHost"], saved["newReplicaHost"], saved["oldHost"], saved["oldReplicaHost"]):
        raise ValueError("Live database endpoints differ from the saved failback record.")
    if any(instance["Endpoint"]["Port"] != source["Endpoint"]["Port"] for instance in databases):
        raise ValueError("Database ports differ; endpoint-only update is not sufficient.")
    mode = event.get("mode", "auto")
    current_hosts = (secret.get("DB_HOST"), secret.get("DB_REPLICA_HOST"))
    if mode == "manual":
        if current_hosts != new_hosts:
            raise ValueError("Manual update not verified: both secret endpoints must match the displayed targets.")
        if path.exists():
            saved_record = load_cutover(event["ledger_dir"], run_id, event["account"], event["region"])
            saved_ids = (saved_record["source_db"], saved_record["source_replica"],
                         saved_record["db"], saved_record["replica"])
            saved_hosts = (saved_record["oldHost"], saved_record["oldReplicaHost"],
                           saved_record["newHost"], saved_record["newReplicaHost"])
            if (saved_record["secretArn"] != metadata["ARN"] or saved_ids != tuple(identifiers)
                    or saved_hosts != old_hosts + new_hosts):
                raise ValueError("Manual endpoints do not match the saved DR run.")
        elif event.get("apply") == "true":
            previous = next((version for version, stages in metadata["VersionIdsToStages"].items()
                             if "AWSPREVIOUS" in stages), previous)
            save_record(path, {
                "runId": run_id, "operation": "cutover", "mode": "manual",
                "secretName": metadata["Name"], "secretArn": metadata["ARN"],
                "account": event["account"], "region": event["region"],
                "previousVersion": previous, "newVersion": current[0],
                "oldHost": old_hosts[0], "oldReplicaHost": old_hosts[1],
                "newHost": new_hosts[0], "newReplicaHost": new_hosts[1],
                "source_db": event["source_db"], "source_replica": event["source_replica"],
                "db": event["db"], "replica": event["replica"],
                "createdAt": datetime.now(timezone.utc).isoformat(), "status": "complete",
            }, exclusive=True)
        return {"runId": run_id, "operation": operation, "mode": "manual",
                "secretName": metadata["Name"], "previousVersion": previous,
                "newVersion": current[0], "oldHost": new_hosts[0], "oldReplicaHost": new_hosts[1],
                "newHost": new_hosts[0], "newReplicaHost": new_hosts[1],
                "applied": False, "manualVerified": True}
    if mode != "auto":
        raise ValueError("Mode must be auto or manual.")
    if current_hosts != old_hosts:
        raise ValueError("Secret endpoints do not match BOTH old databases. No update made.")
    result = {"runId": run_id, "operation": operation,
              "secretName": metadata["Name"], "secretArn": metadata["ARN"],
              "previousVersion": previous, "newVersion": previous,
              "oldHost": old_hosts[0], "oldReplicaHost": old_hosts[1],
              "newHost": new_hosts[0], "newReplicaHost": new_hosts[1], "applied": False}
    if event.get("apply") != "true":
        return result
    updated = dict(secret, DB_HOST=new_hosts[0], DB_REPLICA_HOST=new_hosts[1])
    token = str(uuid.uuid4())
    stage = "DR-endpoint-" + token
    record = dict(result, account=event["account"], region=event["region"],
                  createdAt=datetime.now(timezone.utc).isoformat(), status="prepared", newVersion=token,
                  source_db=event["source_db"], source_replica=event["source_replica"],
                  db=event["db"], replica=event["replica"])
    save_record(path, record, exclusive=True)
    new = sm.put_secret_value(SecretId=metadata["ARN"], ClientRequestToken=token,
                              VersionStages=[stage], SecretString=json.dumps(updated, allow_nan=False))
    record.update(newVersion=new["VersionId"], status="staged")
    save_record(path, record)
    sm.update_secret_version_stage(SecretId=metadata["ARN"], VersionStage="AWSCURRENT",
                                   MoveToVersionId=new["VersionId"], RemoveFromVersionId=previous)
    record.update(status="promoted")
    save_record(path, record)
    verified = sm.get_secret_value(SecretId=metadata["ARN"], VersionId=new["VersionId"], VersionStage="AWSCURRENT")
    if json.loads(verified["SecretString"], object_pairs_hook=unique_object) != updated:
        raise RuntimeError("Post-update verification failed. Inspect version metadata before retrying.")
    result.update(newVersion=new["VersionId"], applied=True, unchangedFieldsVerified=True)
    record.update(result, status="complete")
    save_record(path, record)
    sm.update_secret_version_stage(SecretId=metadata["ARN"], VersionStage=stage,
                                   RemoveFromVersionId=new["VersionId"])
    return result


def main(arguments):
    try:
        if arguments[0] == "--show-run":
            _, directory, selection, account, region = arguments
            print(json.dumps(load_cutover(directory, selection, account, region)))
            return 0
        if arguments[0] == "--show-failback":
            _, directory, run_id = arguments
            if not re.fullmatch(r"DR-[A-Za-z0-9_-]{1,120}", run_id):
                raise ValueError("A valid explicit DR- run ID is required for failback app evidence.")
            run_dir = Path(directory) / run_id
            try:
                cutover = json.loads((run_dir / "cutover.json").read_text())
            except (OSError, ValueError):
                raise ValueError("A completed matching cutover is required for this failback run.") from None
            print(json.dumps(load_failback_context(
                directory, run_id, cutover.get("account", ""), cutover.get("region", "")
            )))
            return 0
        if arguments[0] == "--record-app-deploy":
            _, directory, run_id, account, region, owner, evidence_ref = arguments
            print(json.dumps(record_app_deployment(directory, run_id, account, region, owner, evidence_ref)))
            return 0
        if arguments[0] == "--record-app-health":
            _, directory, run_id, account, region, owner, evidence_ref, t0_at = arguments
            print(json.dumps(record_app_health(directory, run_id, account, region, owner, evidence_ref, t0_at)))
            return 0
        if arguments[0] == "--record-app-e2e":
            _, directory, run_id, account, region, owner, transaction_ref = arguments
            print(json.dumps(record_app_e2e(directory, run_id, account, region, owner, transaction_ref)))
            return 0
        if arguments[0] == "--record-failback-app-deploy":
            _, directory, run_id, account, region, owner, evidence_ref = arguments
            print(json.dumps(record_failback_app_deployment(
                directory, run_id, account, region, owner, evidence_ref
            )))
            return 0
        if arguments[0] == "--record-failback-app-health":
            _, directory, run_id, account, region, owner, evidence_ref, health_at = arguments
            print(json.dumps(record_failback_app_health(
                directory, run_id, account, region, owner, evidence_ref, health_at
            )))
            return 0
        if arguments[0] == "--record-failback-app-e2e":
            _, directory, run_id, account, region, owner, transaction_ref, transaction_at = arguments
            print(json.dumps(record_failback_app_e2e(
                directory, run_id, account, region, owner, transaction_ref, transaction_at
            )))
            return 0
        if arguments[0] == "--review-failback-signoff":
            _, directory, run_id, account, region = arguments
            print(json.dumps(failback_signoff_review(directory, run_id, account, region)))
            return 0
        if arguments[0] == "--record-failback-signoff":
            print(json.dumps(record_failback_signoff(*arguments[1:])))
            return 0
        if arguments[0] == "--retirement-context":
            print(json.dumps(retirement_context(*arguments[1:])))
            return 0
        if arguments[0] == "--check-fence":
            _, path, run_id, account, region, active_primary, active_replica, return_primary, return_replica = arguments
            return 0 if verified_fence_record(
                path, run_id, account, region, active_primary, active_replica,
                return_primary, return_replica
            ) else 1
        profile, region, secret_id, confirmed, apply, expected, source, old_replica, target, replica, account, run_id, directory, operation, mode = arguments
        event = {"secret_id": secret_id, "confirmed_secret": confirmed, "apply": apply,
                 "expected_version": expected, "source_db": source, "source_replica": old_replica,
                 "db": target, "replica": replica, "account": account, "region": region,
                 "run_id": run_id, "ledger_dir": directory, "operation": operation, "mode": mode}
        result = bb3_update(event, AwsCliClient(profile, region, "rds"),
                            AwsCliClient(profile, region, "secretsmanager"))
    except (ValueError, RuntimeError) as error:
        print(str(error), file=sys.stderr)
        return 1
    except Exception:
        print("Secret operation failed; details withheld. Inspect current version metadata before retrying.", file=sys.stderr)
        return 1
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))