import copy
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
import runpy


ROOT = Path(__file__).resolve().parents[3]
HANDLER = runpy.run_path(str(ROOT / "iac/lab/bb3-db/secret-endpoints.py"))


class SecretEndpointTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
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
            "run_id": "DR-fixture", "ledger_dir": self.directory.name,
            "account": "000000000000", "region": "ap-southeast-1",
        }

    def execute(self, **changes):
        return HANDLER["bb3_update"](dict(self.event, **changes), self.rds, self.sm)

    def test_verified_fence_accepts_stopped_instance(self):
        record = {
            "runId": "DR-fixture", "account": "000000000000", "region": "ap-southeast-1",
            "status": "owner-confirmed", "activePrimary": "old-primary", "activeReplica": "old-replica",
            "returnPrimary": "new-primary", "returnReplica": "new-replica",
            "fenceMethod": "rds-stopped", "fenceVerified": True, "rdsStopConfirmed": True,
        }
        path = Path(self.directory.name) / "fence.json"
        path.write_text(json.dumps(record))
        self.assertTrue(HANDLER["verified_fence_record"](
            path, "DR-fixture", "000000000000", "ap-southeast-1",
            "old-primary", "old-replica", "new-primary", "new-replica"
        ))

    def test_verified_quarantine_requires_session_closure(self):
        record = {
            "runId": "DR-fixture", "account": "000000000000", "region": "ap-southeast-1",
            "status": "owner-confirmed", "activePrimary": "old-primary", "activeReplica": "old-replica",
            "returnPrimary": "new-primary", "returnReplica": "new-replica",
            "fenceMethod": "security-group-no-ingress", "fenceVerified": True,
            "quarantineSecurityGroup": "sg-fixture", "existingSessionsClosed": False,
        }
        path = Path(self.directory.name) / "fence.json"
        path.write_text(json.dumps(record))
        arguments = (path, "DR-fixture", "000000000000", "ap-southeast-1",
                     "old-primary", "old-replica", "new-primary", "new-replica")
        self.assertFalse(HANDLER["verified_fence_record"](*arguments))
        record["existingSessionsClosed"] = True
        path.write_text(json.dumps(record))
        self.assertTrue(HANDLER["verified_fence_record"](*arguments))
        self.assertFalse(HANDLER["verified_fence_record"](
            path, "DR-fixture", "000000000000", "ap-southeast-1",
            "wrong-primary", "old-replica", "new-primary", "new-replica"
        ))

    def prepare_app_run(self):
        run_dir = Path(self.directory.name) / "DR-fixture"
        run_dir.mkdir(exist_ok=True)
        (run_dir / "cutover.json").write_text(json.dumps({
            "runId": "DR-fixture", "status": "complete", "account": "000000000000",
            "region": "ap-southeast-1", "createdAt": "2026-10-20T00:00:00+00:00",
            "newHost": "new-primary.example.invalid", "newReplicaHost": "new-replica.example.invalid",
        }))
        (run_dir / "app-deploy.json").write_text(json.dumps({
            "runId": "DR-fixture", "status": "owner-confirmed", "appOwner": "owner@example.invalid",
            "servicesConverged": True,
        }))
        return run_dir

    def test_t8_requires_completed_deployment_and_records_connectivity(self):
        run_dir = self.prepare_app_run()
        with self.assertRaises(ValueError):
            HANDLER["record_app_health"](self.directory.name, "DR-fixture", "000000000000",
                                         "ap-southeast-1", "other@example.invalid", "health-check-1",
                                         "2026-10-20T00:00:00Z")
        result = HANDLER["record_app_health"](self.directory.name, "DR-fixture", "000000000000",
                                               "ap-southeast-1", "owner@example.invalid", "health-check-1",
                                               "2026-10-20T00:00:00Z")
        self.assertTrue(result["connectivityVerified"])
        self.assertEqual(result["primaryHost"], "new-primary.example.invalid")
        self.assertEqual(result["t0At"], "2026-10-20T00:00:00+00:00")
        self.assertGreater(result["serviceRtoMinutes"], 0)
        self.assertTrue(result["t8At"].endswith("+00:00"))
        self.assertTrue((run_dir / "app-health.json").exists())

    def test_t9_requires_t8_and_records_transaction_validation_separately(self):
        self.prepare_app_run()
        with self.assertRaisesRegex(ValueError, "T8 app-connectivity confirmation"):
            HANDLER["record_app_e2e"](self.directory.name, "DR-fixture", "000000000000",
                                      "ap-southeast-1", "owner@example.invalid", "txn-123")
        t8 = HANDLER["record_app_health"](self.directory.name, "DR-fixture", "000000000000",
                                          "ap-southeast-1", "owner@example.invalid", "health-check-1",
                                          "2026-10-20T00:00:00Z")
        t9 = HANDLER["record_app_e2e"](self.directory.name, "DR-fixture", "000000000000",
                                        "ap-southeast-1", "owner@example.invalid", "txn-123")
        self.assertEqual(t9["t8At"], t8["t8At"])
        self.assertEqual(t9["t0At"], t8["t0At"])
        self.assertEqual(t9["serviceRtoMinutes"], t8["serviceRtoMinutes"])
        self.assertEqual(t9["transactionRef"], "txn-123")
        self.assertTrue(t9["transactionSucceeded"])
        self.assertGreaterEqual(t9["businessValidationMinutes"], 0)

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
        self.assertEqual(run.call_args.kwargs["input"], json.dumps(self.original))

    def test_cli_converts_acronym_parameters(self):
        with patch.object(HANDLER["subprocess"], "run", return_value=Mock(returncode=0, stdout='{"DBInstances":[]}')) as run:
            client = HANDLER["AwsCliClient"]("lab_sandbox", "ap-southeast-1", "rds")
            client.describe_db_instances(DBInstanceIdentifier="primary")
        self.assertIn("--db-instance-identifier", run.call_args.args[0])
        self.assertNotIn("--d-b-instance-identifier", run.call_args.args[0])

    def test_backup_exists_before_first_write_and_is_sanitized(self):
        def check_backup(**request):
            path = Path(self.directory.name) / "DR-fixture/cutover.json"
            record = json.loads(path.read_text())
            self.assertEqual(record["status"], "prepared")
            self.assertEqual(record["oldHost"], self.original["DB_HOST"])
            self.assertNotIn("synthetic-test-only", path.read_text())
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            return {"VersionId": "version-new"}
        self.sm.put_secret_value.side_effect = check_backup
        self.execute()
        record = HANDLER["load_cutover"](self.directory.name, "latest", "000000000000", "ap-southeast-1")
        self.assertEqual(record["runId"], "DR-fixture")
        self.assertEqual(record["status"], "complete")

    def test_backup_failure_blocks_secret_write(self):
        with patch.dict(HANDLER["bb3_update"].__globals__, save_record=Mock(side_effect=OSError("disk full"))):
            with self.assertRaises(OSError):
                self.execute()
        self.sm.put_secret_value.assert_not_called()

    def test_failback_preserves_current_rotated_password(self):
        self.execute()
        self.metadata["VersionIdsToStages"] = {"version-rotated": ["AWSCURRENT"]}
        rotated = dict(self.updated, DB_PASSWORD="synthetic-rotated")
        returned = dict(rotated, DB_HOST=self.original["DB_HOST"], DB_REPLICA_HOST=self.original["DB_REPLICA_HOST"])
        self.sm.get_secret_value.side_effect = lambda **request: {
            "SecretString": json.dumps(returned if request["VersionId"] == "version-returned" else rotated)
        }
        self.sm.put_secret_value.return_value = {"VersionId": "version-returned"}
        self.execute(operation="failback", source_db="new-primary", source_replica="new-replica",
                     db="old-primary", replica="old-replica", expected_version="version-rotated")
        self.assertEqual(json.loads(self.sm.put_secret_value.call_args.kwargs["SecretString"]), returned)

    def test_failed_or_duplicate_run_cannot_be_selected_or_replayed(self):
        self.sm.update_secret_version_stage.side_effect = RuntimeError("Concurrent update")
        with self.assertRaises(RuntimeError):
            self.execute()
        self.sm.put_secret_value.reset_mock()
        with self.assertRaises(ValueError):
            self.execute()
        self.sm.put_secret_value.assert_not_called()
        with self.assertRaises(ValueError):
            HANDLER["load_cutover"](self.directory.name, "latest", "000000000000", "ap-southeast-1")

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

    def test_manual_mode_verifies_target_hosts_without_secret_write(self):
        self.sm.get_secret_value.side_effect = None
        self.sm.get_secret_value.return_value = {"SecretString": json.dumps(self.updated)}
        preview = self.execute(mode="manual", apply="false")
        self.assertTrue(preview["manualVerified"])
        self.assertFalse(preview["applied"])
        self.sm.put_secret_value.assert_not_called()
        self.sm.update_secret_version_stage.assert_not_called()

    def test_manual_mode_requires_both_expected_hosts(self):
        self.sm.get_secret_value.side_effect = None
        wrong = dict(self.updated, DB_REPLICA_HOST="unexpected.example.invalid")
        self.sm.get_secret_value.return_value = {"SecretString": json.dumps(wrong)}
        with self.assertRaisesRegex(ValueError, "Manual update not verified"):
            self.execute(mode="manual", apply="true")
        self.sm.put_secret_value.assert_not_called()
        self.assertFalse((Path(self.directory.name) / "DR-fixture/cutover.json").exists())

    def test_manual_confirmation_journals_metadata_only(self):
        self.sm.get_secret_value.side_effect = None
        self.sm.get_secret_value.return_value = {"SecretString": json.dumps(self.updated)}
        result = self.execute(mode="manual", apply="true")
        journal = Path(self.directory.name) / "DR-fixture/cutover.json"
        saved = json.loads(journal.read_text())
        self.assertTrue(result["manualVerified"])
        self.assertEqual(saved["mode"], "manual")
        self.assertEqual(saved["status"], "complete")
        self.assertEqual(saved["newVersion"], "version-old")
        self.assertNotIn("synthetic-test-only", journal.read_text())
        self.sm.put_secret_value.assert_not_called()

    def test_manual_app_deployment_confirmation_records_owner_and_log_reference(self):
        self.execute()
        result = HANDLER["record_app_deployment"](
            self.directory.name, "DR-fixture", "000000000000", "ap-southeast-1",
            "App Owner", "evidence/DR-fixture/app-deploy.log")
        self.assertEqual(result["status"], "owner-confirmed")
        self.assertEqual(result["evidenceRef"], "evidence/DR-fixture/app-deploy.log")
        self.assertNotIn("deployedCommit", result)
        self.assertTrue(result["servicesConverged"])
        self.assertNotIn("synthetic-test-only", json.dumps(result))
        with self.assertRaises(ValueError):
            HANDLER["record_app_deployment"](
                self.directory.name, "DR-fixture", "000000000000", "ap-southeast-1",
                "App Owner", "evidence/DR-fixture/app-deploy.log")

    def test_app_deploy_attestation_requires_evidence_reference(self):
        self.execute()
        with self.assertRaises(ValueError):
            HANDLER["record_app_deployment"](
                self.directory.name, "DR-fixture", "000000000000", "ap-southeast-1",
                "App Owner", " ")


if __name__ == "__main__":
    unittest.main()