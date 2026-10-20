import json
import subprocess
import sys
import uuid


class AwsCliClient:
    def __init__(self, profile, region, service):
        self.profile = profile
        self.region = region
        self.service = service

    def call(self, action, request):
        result = subprocess.run(
            ["aws", "--profile", self.profile, "--region", self.region,
             "--no-cli-pager", self.service, action,
             "--cli-input-json", "file:///dev/stdin", "--output", "json"],
            input=json.dumps(request, allow_nan=False), capture_output=True,
            text=True, timeout=90,
        )
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


def bb3_update(event, rds, sm):
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
    if (secret.get("DB_HOST"), secret.get("DB_REPLICA_HOST")) != old_hosts:
        raise ValueError("Secret endpoints do not match BOTH old databases. No update made.")
    if any(instance["Endpoint"]["Port"] != source["Endpoint"]["Port"] for instance in databases):
        raise ValueError("Database ports differ; endpoint-only update is not sufficient.")
    result = {"secretName": metadata["Name"], "secretArn": metadata["ARN"],
              "previousVersion": previous, "newVersion": previous,
              "oldHost": old_hosts[0], "oldReplicaHost": old_hosts[1],
              "newHost": new_hosts[0], "newReplicaHost": new_hosts[1], "applied": False}
    if event.get("apply") != "true":
        return result
    updated = dict(secret, DB_HOST=new_hosts[0], DB_REPLICA_HOST=new_hosts[1])
    token = str(uuid.uuid4())
    stage = "DR-endpoint-" + token
    new = sm.put_secret_value(SecretId=metadata["ARN"], ClientRequestToken=token,
                              VersionStages=[stage], SecretString=json.dumps(updated, allow_nan=False))
    sm.update_secret_version_stage(SecretId=metadata["ARN"], VersionStage="AWSCURRENT",
                                   MoveToVersionId=new["VersionId"], RemoveFromVersionId=previous)
    verified = sm.get_secret_value(SecretId=metadata["ARN"], VersionId=new["VersionId"], VersionStage="AWSCURRENT")
    if json.loads(verified["SecretString"], object_pairs_hook=unique_object) != updated:
        raise RuntimeError("Post-update verification failed. Inspect version metadata before retrying.")
    result.update(newVersion=new["VersionId"], applied=True, unchangedFieldsVerified=True)
    sm.update_secret_version_stage(SecretId=metadata["ARN"], VersionStage=stage,
                                   RemoveFromVersionId=new["VersionId"])
    return result


def main(arguments):
    profile, region, secret_id, confirmed, apply, expected, source, old_replica, target, replica = arguments
    event = {"secret_id": secret_id, "confirmed_secret": confirmed, "apply": apply,
             "expected_version": expected, "source_db": source, "source_replica": old_replica,
             "db": target, "replica": replica}
    try:
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