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