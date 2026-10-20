import copy
import json
from pathlib import Path
import unittest
from unittest.mock import Mock, patch
import runpy


ROOT = Path(__file__).resolve().parents[3]
HANDLER = runpy.run_path(str(ROOT / "iac/lab/bb3-db/secret-endpoints.py"))


class SecretEndpointTests(unittest.TestCase):
    def setUp(self):
        self.databases = {}
        for identifier in ("old-primary", "old-replica", "new-primary", "new-replica"):
            instance = {
                "DBInstanceIdentifier": identifier,
                "Engine": "postgres",
                "DBInstanceStatus": "available",
                "Endpoint": {"Address": identifier + ".example.invalid", "Port": 5432},
            }
            if identifier.endswith("replica"):
                instance["ReadReplicaSourceDBInstanceIdentifier"] = identifier.replace("replica", "primary")
            self.databases[identifier] = instance
        self.rds = Mock()
        self.rds.describe_db_instances.side_effect = lambda DBInstanceIdentifier: {
            "DBInstances": [self.databases[DBInstanceIdentifier]]
        }
        self.sm = Mock()
        self.metadata = {
            "ARN": "arn:aws:secretsmanager:ap-southeast-1:000000000000:secret:fixture",
            "Name": "fixture",
            "VersionIdsToStages": {"version-old": ["AWSCURRENT"]},
        }
        self.original = {
            "DB_HOST": "old-primary.example.invalid",
            "DB_REPLICA_HOST": "old-replica.example.invalid",
            "DB_NAME": "fixture-db",
            "DB_USER": "fixture-user",
            "DB_PASSWORD": "synthetic-test-only",
            "unrelated": {"nested": [True, 12]},
        }
        self.sm.describe_secret.return_value = self.metadata
        self.updated = dict(self.original, DB_HOST="new-primary.example.invalid", DB_REPLICA_HOST="new-replica.example.invalid")
        self.sm.get_secret_value.side_effect = lambda **request: {
            "SecretString": json.dumps(self.updated if request["VersionId"] == "version-new" else self.original)
        }
        self.sm.put_secret_value.return_value = {"VersionId": "version-new"}
        self.event = {
            "schema": "bb3", "secret_id": "fixture", "source_db": "old-primary",
            "source_replica": "old-replica", "db": "new-primary", "replica": "new-replica",
            "apply": "true", "confirmed_secret": "fixture", "expected_version": "version-old",
        }

    def execute(self, **changes):
        return HANDLER["bb3_update"](dict(self.event, **changes), self.rds, self.sm)

    def test_preview_is_read_only_and_sanitized(self):
        result = self.execute(apply="false")
        self.assertFalse(result["applied"])
        self.sm.put_secret_value.assert_not_called()
        self.sm.update_secret_version_stage.assert_not_called()
        self.assertNotIn("synthetic-test-only", json.dumps(result))
        self.assertNotIn("DB_PASSWORD", json.dumps(result))

    def test_update_preserves_all_other_values(self):
        result = self.execute()
        expected = copy.deepcopy(self.original)
        expected.update(DB_HOST="new-primary.example.invalid", DB_REPLICA_HOST="new-replica.example.invalid")
        self.assertEqual(json.loads(self.sm.put_secret_value.call_args.kwargs["SecretString"]), expected)
        self.assertTrue(result["applied"])
        self.assertEqual(result["previousVersion"], "version-old")
        self.assertEqual(result["newVersion"], "version-new")
        self.sm.get_secret_value.assert_any_call(
            SecretId=self.metadata["ARN"], VersionId="version-old", VersionStage="AWSCURRENT"
        )

    def test_exact_secret_confirmation_required(self):
        for confirmation in ("", "wrong", "FIXTURE"):
            with self.subTest(confirmation=confirmation), self.assertRaises(ValueError):
                self.execute(confirmed_secret=confirmation)
        self.sm.put_secret_value.assert_not_called()

    def test_full_arn_confirmation_accepted(self):
        self.assertTrue(self.execute(confirmed_secret=self.metadata["ARN"])["applied"])

    def test_preview_version_required(self):
        for version in ("", "stale"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                self.execute(expected_version=version)
        self.sm.put_secret_value.assert_not_called()

    def test_both_old_endpoints_must_match(self):
        for key in ("DB_HOST", "DB_REPLICA_HOST"):
            with self.subTest(key=key):
                changed = dict(self.original, **{key: "wrong.example.invalid"})
                self.sm.get_secret_value.side_effect = None
                self.sm.get_secret_value.return_value = {"SecretString": json.dumps(changed)}
                with self.assertRaises(ValueError):
                    self.execute()
        self.sm.put_secret_value.assert_not_called()

    def test_replica_relationships_checked(self):
        for identifier in ("old-replica", "new-replica"):
            with self.subTest(identifier=identifier):
                saved = self.databases[identifier].pop("ReadReplicaSourceDBInstanceIdentifier")
                with self.assertRaises(ValueError):
                    self.execute()
                self.databases[identifier]["ReadReplicaSourceDBInstanceIdentifier"] = saved
        self.sm.put_secret_value.assert_not_called()

    def test_unavailable_database_rejected(self):
        self.databases["new-primary"]["DBInstanceStatus"] = "modifying"
        with self.assertRaises(ValueError):
            self.execute()
        self.sm.get_secret_value.assert_not_called()

    def test_rotating_secret_rejected(self):
        self.metadata["RotationEnabled"] = True
        with self.assertRaises(ValueError):
            self.execute()
        self.sm.get_secret_value.assert_not_called()

    def test_invalid_json_is_not_echoed(self):
        self.sm.get_secret_value.side_effect = None
        self.sm.get_secret_value.return_value = {"SecretString": "synthetic-test-only-invalid-json"}
        with self.assertRaisesRegex(ValueError, "^Secret must be a JSON string object.$"):
            self.execute()
        self.sm.put_secret_value.assert_not_called()

    def test_staged_promotion_uses_expected_current_version(self):
        self.sm.update_secret_version_stage.side_effect = RuntimeError("Concurrent update")
        with self.assertRaises(RuntimeError):
            self.execute()
        stages = self.sm.put_secret_value.call_args.kwargs["VersionStages"]
        self.assertTrue(stages[0].startswith("DR-endpoint-"))
        self.assertNotIn("AWSCURRENT", stages)
        self.assertEqual(self.sm.update_secret_version_stage.call_args.kwargs["RemoveFromVersionId"], "version-old")

    def test_cli_payload_uses_stdin_not_arguments(self):
        with patch.object(HANDLER["subprocess"], "run", return_value=Mock(returncode=0, stdout='{"VersionId":"new"}')) as run:
            client = HANDLER["AwsCliClient"]("lab_sandbox", "ap-southeast-1", "secretsmanager")
            client.put_secret_value(SecretId="fixture", SecretString=json.dumps(self.original))
        self.assertNotIn("synthetic-test-only", str(run.call_args.args))
        self.assertIn("file:///dev/stdin", run.call_args.args[0])
        self.assertEqual(json.loads(run.call_args.kwargs["input"])["SecretString"], json.dumps(self.original))

    def test_post_update_verification(self):
        self.sm.get_secret_value.side_effect = lambda **request: {"SecretString": json.dumps(self.original)}
        with self.assertRaisesRegex(RuntimeError, "Post-update verification failed"):
            self.execute()

    def test_duplicate_keys_rejected(self):
        self.sm.get_secret_value.side_effect = None
        self.sm.get_secret_value.return_value = {"SecretString": '{"DB_HOST":"one","DB_HOST":"two"}'}
        with self.assertRaises(ValueError):
            self.execute()
        self.sm.put_secret_value.assert_not_called()


if __name__ == "__main__":
    unittest.main()