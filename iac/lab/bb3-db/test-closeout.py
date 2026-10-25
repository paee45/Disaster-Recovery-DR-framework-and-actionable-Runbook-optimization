from datetime import datetime, timezone
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("closeout", Path(__file__).with_name("closeout.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
NOW = datetime(2026, 10, 21, 2, tzinfo=timezone.utc)


class CloseoutTests(unittest.TestCase):
    def test_prompt_colors_and_no_color_policy(self):
        tty = type("TTY", (), {"isatty": lambda self: True})()
        with patch.object(MODULE.sys, "stdin", tty), patch.object(MODULE.sys, "stdout", tty), \
                patch.dict(os.environ, {"TERM": "xterm"}, clear=True):
            self.assertEqual(MODULE.question_prompt("Question? "), "\033[1;33mQuestion? \033[0m")
            self.assertEqual(MODULE.token_prompt("Type ", "GO", ": "),
                             "\033[1;33mType \033[1;35mGO\033[1;33m: \033[0m")
            with patch.dict(os.environ, {"NO_COLOR": ""}):
                self.assertEqual(MODULE.question_prompt("Question? "), "Question? ")
            with patch.dict(os.environ, {"TERM": "dumb"}):
                self.assertEqual(MODULE.token_prompt("Type ", "GO", ": "), "Type GO: ")

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.ledger = self.root / "evidence/runs"
        self.run = self.ledger / "DR-fixture"
        self.run.mkdir(parents=True)
        self.target_environment = patch.dict(os.environ, {"BB3_RTO_TARGET_MIN": "30"})
        self.target_environment.start()
        self.addCleanup(self.target_environment.stop)
        self.identity = dict(runId="DR-fixture", account="000000000000", region="ap-southeast-1")
        self.records = {
            "incident.json": dict(status="declared", environment="uat", scenario="S3",
                                  t0At="2026-10-21T00:00:00Z", t1At="2026-10-21T00:01:00Z", t0EvidenceRef="monitor-ref"),
            "cutover.json": dict(status="complete", operation="cutover", source_db="old-primary",
                                 source_replica="old-replica", db="new-primary", replica="new-replica",
                                 newHost="primary.example.invalid", newReplicaHost="replica.example.invalid"),
            "fence.json": dict(status="owner-confirmed", appOwner="fixture-owner", fenceVerified=True,
                               existingSessionsClosed=True, activePrimary="old-primary", activeReplica="old-replica",
                               returnPrimary="new-primary", returnReplica="new-replica"),
            "app-deploy.json": dict(status="owner-confirmed", appOwner="fixture-owner", servicesConverged=True,
                                    evidenceRef="deploy-ref", primaryHost="primary.example.invalid", replicaHost="replica.example.invalid"),
            "app-health.json": dict(status="owner-confirmed", appOwner="fixture-owner", connectivityVerified=True,
                                    evidenceRef="health-ref", primaryHost="primary.example.invalid", replicaHost="replica.example.invalid",
                                    t0At="2026-10-21T00:00:00Z", t8At="2026-10-21T00:46:00Z"),
            "app-e2e.json": dict(status="owner-confirmed", appOwner="fixture-owner", transactionSucceeded=True,
                                 transactionRef="txn-fixture", t0At="2026-10-21T00:00:00Z",
                                 t8At="2026-10-21T00:46:00Z", t9At="2026-10-21T00:50:00Z"),
        }
        for name, record in self.records.items():
            record.update(self.identity)
            if name == "app-deploy.json":
                del record["account"]
                del record["region"]
            self.write(name, record)
        self.workflow = MODULE.Closeout(self.root, self.ledger, "DR-fixture", "000000000000", "ap-southeast-1", "uat")
        self.addCleanup(patch.stopall)
        patch.object(MODULE, "utc_now", return_value=NOW).start()
        patch("sys.stdout", new_callable=io.StringIO).start()
        self.ignore = patch.object(MODULE, "git_ignored", return_value=True).start()

    def write(self, name, record):
        (self.run / name).write_text(json.dumps(record))

    def declare(self, answers=None):
        answers = answers if answers is not None else ["approver", "incident commander", "",
                  "none", "DECLARE-RESTORED"]
        with patch("builtins.input", side_effect=answers):
            return self.workflow.declare()

    def package(self):
        with patch("builtins.input", side_effect=AssertionError("Packaging must not prompt")):
            return self.workflow.package()

    def test_declare_preserves_old_milestones_and_missed_rto(self):
        before = {name: (self.run / name).read_bytes() for name in MODULE.REQUIRED}
        result = self.declare()
        self.assertEqual(result["status"], "service-restored")
        self.assertNotIn("approvalRef", result)
        self.assertEqual(result["originalT0EvidenceRef"], "monitor-ref")
        self.assertEqual(result["t0EvidenceRef"], "monitor-ref")
        self.assertEqual(result["t10At"], NOW.isoformat())
        self.assertEqual(before, {name: (self.run / name).read_bytes() for name in MODULE.REQUIRED})
        self.assertIn("MISS", self.workflow.summary(self.workflow.load()[2]))
        self.assertEqual((self.run / "closeout.json").stat().st_mode & 0o777, 0o600)

    def test_summary_explains_milestones_and_unverified_rpo(self):
        output = self.workflow.summary(self.workflow.load()[2])
        self.assertIn("RTO MISS | 46.00 min / 30 min target", output)
        self.assertIn("exceeded by 16.00 min", output)
        self.assertIn("start of the recovery clock", output)
        self.assertIn("T0 is T-zero", output)
        self.assertIn("T8 is a timestamp", output)
        self.assertIn("SERVICE IMPACT START / RTO CLOCK STARTS", output)
        self.assertIn("APP HEALTH RESTORED / RTO CLOCK ENDS", output)
        self.assertIn("Time (UTC): 2026-10-21T00:46:00Z", output)
        self.assertIn("SERVICE RTO (T8-T0): 46.00 min | MISS | Target: 30 min", output)
        self.assertIn("Additional validation (T9-T8): 4.00 min", output)
        self.assertIn("declaring the incident does not restart the clock", output)
        self.assertIn("DB availability alone is not T8", output)
        self.assertIn("not the RTO endpoint", output)
        self.assertIn("Total through T9: 50.00 min", output)
        self.assertIn("RPO: NOT VERIFIED | Target: no more than 24 hours", output)
        self.assertIn("cannot report a snapshot-age RPO pass/fail", output)
        self.assertIn("does not mean zero loss", output)
        self.assertIn("No run-bound restore snapshot metadata", output)
        self.assertIn("verification is deferred", output)
        self.assertIn("T10 is separate from T8", output)
        self.assertNotIn("\033[", output)

    def test_bb3_default_and_configured_rto_targets(self):
        for configured, target, result in ((None, 60, "PASS"), ("60", 60, "PASS"),
                                            ("45", 45, "MISS"), ("30", 30, "MISS")):
            with self.subTest(configured=configured), patch.dict(os.environ, {}, clear=True):
                if configured is not None:
                    os.environ["BB3_RTO_TARGET_MIN"] = configured
                workflow = MODULE.Closeout(self.root, self.ledger, "DR-fixture", "000000000000",
                                           "ap-southeast-1", "uat")
                self.assertEqual(workflow.rto_target_minutes, target)
                output = workflow.summary(workflow.load()[2])
                self.assertIn(f"RTO {result} | 46.00 min / {target} min target", output)

    def test_invalid_rto_target_is_refused(self):
        for value in ("", "invalid", "0", "-1", "nan", "inf"):
            with self.subTest(value=value), patch.dict(os.environ, {"BB3_RTO_TARGET_MIN": value}):
                with self.assertRaisesRegex(ValueError, "BB3_RTO_TARGET_MIN"):
                    MODULE.Closeout(self.root, self.ledger, "DR-fixture", "000000000000",
                                    "ap-southeast-1", "uat")

    def capture_snapshot(self, created="2026-10-20T04:00:00Z"):
        self.write("network-fence.json", dict(self.identity, status="attached",
                   activePrimary="old-primary", activeReplica="old-replica"))
        snapshot = dict(DBSnapshotIdentifier="rds:fixture-daily", DBInstanceIdentifier="old-primary",
                        Status="available", SnapshotType="automated", SnapshotCreateTime=created)
        return self.workflow.capture_snapshot(snapshot, "old-primary", "new-primary", "rds:fixture-daily")

    def test_snapshot_based_rpo_is_verified_without_business_data_claim(self):
        captured = self.capture_snapshot()
        records, contents, times = self.workflow.load()
        self.assertIn("snapshot-recovery.json", contents)
        output = self.workflow.summary(times)
        self.assertIn("RPO: VERIFIED (snapshot-based) | PASS | Target: 24 hours", output)
        self.assertIn("Snapshot age at impact T0: 20.00 hours", output)
        self.assertIn("transaction-level data completeness verification is deferred", output)
        metrics = self.workflow.recovery_metrics(times)
        self.assertEqual(metrics["rpo"]["actualSeconds"], 72000)
        self.assertFalse(metrics["rpo"]["businessDataVerified"])
        self.assertEqual(captured["restoredPrimary"], records["cutover.json"]["db"])
        self.assertEqual(self.capture_snapshot(), captured)

    def test_snapshot_capture_cli_saves_run_bound_evidence(self):
        self.capture_snapshot()
        (self.run / "snapshot-recovery.json").unlink()
        snapshot = dict(DBSnapshotIdentifier="rds:fixture-daily", DBInstanceIdentifier="old-primary",
                        Status="available", SnapshotType="automated", SnapshotCreateTime="2026-10-20T04:00:00Z")
        arguments = ["closeout.py", "capture-snapshot", "--root", str(self.root), "--ledger", str(self.ledger),
                     "--run-id", "DR-fixture", "--account", "000000000000", "--region", "ap-southeast-1",
                     "--environment", "uat", "--snapshot-json", json.dumps(snapshot),
                     "--snapshot-id", "rds:fixture-daily", "--source-db", "old-primary",
                     "--restored-primary", "new-primary"]
        with patch.object(MODULE.sys, "argv", arguments):
            self.assertEqual(MODULE.main(), 0)
        output = self.workflow.summary(self.workflow.load()[2])
        self.assertIn("RPO: VERIFIED (snapshot-based) | PASS", output)

    def test_configured_rto_boundaries_use_unrounded_elapsed_time(self):
        for target in (45, 60):
            with self.subTest(target=target):
                self.workflow.rto_target_minutes = target
                t0, t1, _, _ = self.workflow.load()[2]
                t8 = t0 + MODULE.timedelta(minutes=target)
                self.assertIn("RTO PASS", self.workflow.summary((t0, t1, t8, t8)))
                t8 += MODULE.timedelta(microseconds=1)
                self.assertIn("RTO MISS", self.workflow.summary((t0, t1, t8, t8)))

    def test_snapshot_rpo_exact_24_hour_boundary(self):
        for created, expected in (("2026-10-20T00:00:00Z", "PASS"),
                                  ("2026-10-19T23:59:59Z", "MISS")):
            with self.subTest(created=created):
                (self.run / "snapshot-recovery.json").unlink(missing_ok=True)
                self.capture_snapshot(created)
                output = self.workflow.summary(self.workflow.load()[2])
                self.assertIn(f"RPO: VERIFIED (snapshot-based) | {expected}", output)

    def test_snapshot_evidence_mismatch_and_future_time_are_refused(self):
        captured = self.capture_snapshot()
        for field, value in (("sourceDb", "wrong-primary"), ("restoredPrimary", "wrong-target"),
                             ("runId", "DR-wrong"), ("snapshotCreatedAt", "invalid"),
                             ("snapshotCreatedAt", "2026-10-21T00:00:01Z")):
            with self.subTest(field=field):
                self.write("snapshot-recovery.json", dict(captured, **{field: value}))
                with self.assertRaises(ValueError):
                    self.workflow.load()
        self.write("snapshot-recovery.json", captured)
        self.declare()
        with self.assertRaisesRegex(ValueError, "after service-restored"):
            self.capture_snapshot()

    def test_snapshot_capture_requires_available_matching_metadata(self):
        self.capture_snapshot()
        snapshot = dict(DBSnapshotIdentifier="rds:fixture-daily", DBInstanceIdentifier="old-primary",
                        Status="available", SnapshotType="automated", SnapshotCreateTime="2026-10-20T04:00:00Z")
        for field, value in (("SnapshotCreateTime", None), ("Status", "creating"),
                             ("DBInstanceIdentifier", "other-primary"),
                             ("DBSnapshotIdentifier", "other-snapshot"), ("SnapshotType", None)):
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.workflow.capture_snapshot(dict(snapshot, **{field: value}), "old-primary",
                                               "new-primary", "rds:fixture-daily")
        with self.assertRaisesRegex(ValueError, "differs"):
            self.capture_snapshot("2026-10-20T05:00:00Z")

    def test_approved_metrics_and_snapshot_are_frozen_for_packaging(self):
        self.capture_snapshot()
        closed = self.declare()
        original = (self.run / "closeout.json").read_bytes()
        self.assertEqual(closed["recoveryMetrics"]["rtoTargetMinutes"], 30)
        with patch.dict(os.environ, {"BB3_RTO_TARGET_MIN": "60"}):
            workflow = MODULE.Closeout(self.root, self.ledger, "DR-fixture", "000000000000",
                                       "ap-southeast-1", "uat")
            receipt = workflow.package()
        package = Path(receipt["location"]) / "snapshot"
        report = (package / "summary.md").read_text()
        self.assertIn("RTO MISS | 46.00 min / 30 min target", report)
        self.assertIn("RPO: VERIFIED (snapshot-based) | PASS", report)
        self.assertEqual(original, (self.run / "closeout.json").read_bytes())
        self.assertTrue((package / "snapshot-recovery.json").exists())

    def test_tampered_saved_metrics_are_refused(self):
        closed = self.declare()
        for value in ([], {"rtoTargetMinutes": True}, dict(closed["recoveryMetrics"], rtoMet=True)):
            with self.subTest(value=value):
                self.write("closeout.json", dict(closed, recoveryMetrics=value))
                with self.assertRaises(ValueError):
                    self.package()

    def test_summary_rto_boundary_and_color_policy(self):
        t0 = MODULE.timestamp("2026-10-21T00:00:00Z")
        t1 = MODULE.timestamp("2026-10-21T00:01:00Z")
        t8 = MODULE.timestamp("2026-10-21T00:30:00Z")
        times = (t0, t1, t8, t8)
        tty = type("TTY", (), {"isatty": lambda self: True})()
        with patch.object(MODULE.sys, "stdout", tty), patch.dict(os.environ, {"TERM": "xterm"}, clear=True):
            output = self.workflow.summary(times, color=True)
            self.assertIn("\033[1;35m" + "=" * 76, output)
            self.assertIn("\033[1;35m  T0 (Impact)", output)
            self.assertIn("\033[1;35m  T8 (Health)", output)
            self.assertIn("Time (UTC): \033[1;36m2026-10-21T00:30:00Z", output)
            self.assertIn("\033[1;32mRECOVERY TIMING RESULT: RTO PASS", output)
            self.assertIn("\033[1;33mRPO: NOT VERIFIED", output)
            self.assertIn("target was met (30.00 min)", output)
            missed = self.workflow.summary(self.workflow.load()[2], color=True)
            self.assertIn("\033[1;31mRECOVERY TIMING RESULT: RTO MISS", missed)
            with patch.dict(os.environ, {"NO_COLOR": ""}):
                self.assertNotIn("\033[", self.workflow.summary(times, color=True))
            with patch.dict(os.environ, {"TERM": "dumb"}):
                self.assertNotIn("\033[", self.workflow.summary(times, color=True))
        self.assertNotIn("\033[", self.workflow.summary(times, color=True))

    def test_package_snapshot_manifest_archive_and_exclusions(self):
        (self.run / "sandbox.env").write_text("PASSWORD=synthetic-never-package")
        (self.run / "nested").mkdir()
        (self.run / "nested/secret.json").write_text("synthetic-never-package")
        (self.run / "app-deploy.log").write_text("reviewed fixture deployment log")
        self.declare()
        receipt = self.package()
        package = Path(receipt["location"])
        snapshot = package / "snapshot"
        manifest = json.loads((snapshot / "manifest.json").read_text())
        for name, expected in manifest["files"].items():
            self.assertEqual(hashlib.sha256((snapshot / name).read_bytes()).hexdigest(), expected)
        self.assertNotIn("manifest.json", manifest["files"])
        self.assertFalse((snapshot / "sandbox.env").exists())
        self.assertFalse((snapshot / "nested").exists())
        self.assertFalse((snapshot / "app-deploy.log").exists())
        self.assertEqual(receipt["evidenceOwner"], "approver")
        self.assertEqual(receipt["packagingMode"], "automatic-local")
        self.assertFalse(receipt["deploymentLogIncluded"])
        with tarfile.open(receipt["archive"], "r:gz") as archive:
            self.assertTrue(all(member.isfile() for member in archive.getmembers()))
            for member in archive.getmembers():
                self.assertNotIn(b"synthetic-never-package", archive.extractfile(member).read())
        self.assertEqual(receipt["archiveSha256"], hashlib.sha256(Path(receipt["archive"]).read_bytes()).hexdigest())
        self.assertFalse(receipt["uploaded"])
        self.assertEqual(receipt["status"], "local-packaged")
        self.assertIn("Baseline/raw API evidence", (snapshot / "summary.md").read_text())
        frozen = (snapshot / "app-e2e.json").read_bytes()
        self.write("app-e2e.json", {})
        self.assertEqual(frozen, (snapshot / "app-e2e.json").read_bytes())

    def test_incident_approver_can_differ_from_app_owner(self):
        closed = self.declare(["incident-lead", "incident commander", "", "none", "DECLARE-RESTORED"])
        self.assertEqual(closed["approver"], "incident-lead")
        self.assertNotEqual(closed["approver"], self.records["app-deploy.json"]["appOwner"])
        receipt = self.package()
        self.assertEqual(receipt["evidenceOwner"], "incident-lead")
        snapshot = Path(receipt["location"]) / "snapshot"
        for name in ("app-deploy.json", "app-health.json", "app-e2e.json"):
            self.assertEqual(json.loads((snapshot / name).read_text())["appOwner"], "fixture-owner")

    def test_different_app_attestation_owner_still_refused(self):
        self.write("app-health.json", dict(self.records["app-health.json"], appOwner="another-app-owner"))
        with self.assertRaisesRegex(ValueError, "App attestation owners do not match"):
            self.declare([])
        self.assertFalse((self.run / "closeout.json").exists())

    def test_invalid_journals_refuse_without_closeout(self):
        cases = [("app-e2e.json", "transactionSucceeded", False), ("app-health.json", "account", "111111111111"),
                 ("fence.json", "existingSessionsClosed", False), ("fence.json", "fenceVerified", False),
                 ("cutover.json", "operation", "failback"), ("app-deploy.json", "servicesConverged", False),
                 ("app-deploy.json", "region", "wrong-region"), ("app-e2e.json", "transactionRef", " "),
                 ("incident.json", "t1At", "2026-10-21T01:00:00Z"),
                 ("app-e2e.json", "t8At", "2026-10-21T00:47:00Z")]
        for name, key, value in cases:
            with self.subTest(name=name, key=key):
                modified = dict(self.records[name], **{key: value})
                self.write(name, modified)
                with self.assertRaises(ValueError):
                    self.declare([])
                self.assertFalse((self.run / "closeout.json").exists())
                self.write(name, self.records[name])
        (self.run / "app-e2e.json").unlink()
        with self.assertRaises(FileNotFoundError):
            self.declare([])

    def test_invalid_t10_and_missing_approval(self):
        for value in ("2026-10-21T00:49:00Z", "2026-10-21T02:01:01Z", "not-time", "2026-10-21T02:00:00"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.declare(["approver", "role", value])
        with self.assertRaises(ValueError):
            self.declare(["approver", "role", "", "", ""])
        self.assertFalse((self.run / "closeout.json").exists())

    def test_no_overwrite(self):
        self.declare()
        original = (self.run / "closeout.json").read_bytes()
        with patch.object(MODULE.sys, "stdout", new_callable=io.StringIO) as output:
            with self.assertRaises(ValueError):
                self.declare([])
            self.assertIn("P4-G4 | RUN ID: DR-fixture", output.getvalue())
            self.assertIn("Service-restored approval already exists", output.getvalue())
            self.assertIn("cannot overwrite or repeat", output.getvalue())
        with self.assertRaises(ValueError):
            self.declare([])
        self.assertEqual(original, (self.run / "closeout.json").read_bytes())
        self.package()
        with self.assertRaises(ValueError):
            self.package()

    def test_legacy_closeout_with_ticket_still_packages(self):
        closed = self.declare()
        closed.pop("recoveryMetrics")
        self.write("closeout.json", dict(closed, approvalRef="legacy-ticket"))
        self.assertEqual(self.package()["status"], "local-packaged")

    def test_package_cli_needs_no_terminal_or_input(self):
        self.declare()
        arguments = ["closeout.py", "package", "--root", str(self.root), "--ledger", str(self.ledger),
                     "--run-id", "DR-fixture", "--account", "000000000000", "--region", "ap-southeast-1",
                     "--environment", "uat"]
        with patch.object(MODULE.sys, "argv", arguments), patch.object(MODULE.sys, "stdin", io.StringIO()), \
                patch("builtins.input", side_effect=AssertionError("Packaging must not prompt")):
            self.assertEqual(MODULE.main(), 0)
        self.assertTrue((self.run / "evidence-package.json").is_file())

    def test_tampered_linked_evidence_refuses_packaging(self):
        self.declare()
        self.write("app-health.json", dict(self.records["app-health.json"], evidenceRef="changed-ref"))
        with self.assertRaisesRegex(ValueError, "changed since declaration|references mismatch"):
            self.package()
        self.assertFalse((self.root / "evidence/bb3-packages").exists())

    def test_symlinks_and_traversal_refused(self):
        for name in ("app-health.json", "app-deploy.log", "run-report.md", "network-fence.json"):
            with self.subTest(name=name):
                path = self.run / name
                path.unlink(missing_ok=True)
                path.symlink_to(self.root / "missing")
                with self.assertRaises((ValueError, OSError)):
                    self.declare([])
                path.unlink()
                if name in self.records:
                    self.write(name, self.records[name])
        with self.assertRaises(ValueError):
            MODULE.Closeout(self.root, self.ledger, "DR-../escape", "000000000000", "ap-southeast-1", "uat")

    def test_package_uses_ignored_default_destination_without_prompts(self):
        self.declare()
        self.ignore.return_value = False
        with self.assertRaises(ValueError):
            self.package()
        self.ignore.return_value = True
        result = self.package()
        self.assertEqual(Path(result["location"]).parent, self.root / "evidence/bb3-packages")

    def test_collision_does_not_overwrite_existing_directory(self):
        self.declare()
        name = "DR-fixture-" + NOW.strftime("%Y%m%dT%H%M%S%fZ")
        existing = self.root / "evidence/bb3-packages" / name
        existing.mkdir(parents=True)
        (existing / "keep").write_text("keep")
        with self.assertRaises(FileExistsError):
            self.package()
        self.assertEqual((existing / "keep").read_text(), "keep")

    def test_declaration_refusal_and_blank_restrictions_default_to_none(self):
        with self.assertRaises(ValueError):
            self.declare(["approver", "role", "", "", ""])
        self.assertFalse((self.run / "closeout.json").exists())
        result = self.declare(["approver", "role", "", "", "DECLARE-RESTORED"])
        self.assertEqual(result["restrictions"], "none")

    def test_edited_t10_and_clock_tolerance(self):
        answers = ["approver", "role", "2026-10-21T02:01:00Z",
             "read-only restriction", "DECLARE-RESTORED"]
        result = self.declare(answers)
        self.assertEqual(result["t10At"], "2026-10-21T02:01:00+00:00")
        self.package()

    def test_evidence_edit_path_requires_final_declaration(self):
        result = self.declare(["approver", "role", "", "none", "EDIT",
                               "corrected-t0-log", "corrected-t8-log", "corrected-t9-id",
                               "DECLARE-RESTORED"])
        self.assertEqual(result["t0EvidenceRef"], "corrected-t0-log")
        self.assertEqual(result["t8EvidenceRef"], "corrected-t8-log")
        self.assertEqual(result["t9EvidenceRef"], "corrected-t9-id")

    def test_each_journal_identity_and_status_checked(self):
        for name in MODULE.REQUIRED:
            for key, value in (("runId", "DR-other"), ("account", "111111111111"),
                               ("region", "wrong-region"), ("status", "failed")):
                with self.subTest(name=name, key=key):
                    self.write(name, dict(self.records[name], **{key: value}))
                    with self.assertRaises(ValueError):
                        self.workflow.load()
                    self.write(name, self.records[name])

    def test_network_fence_validated_and_packaged(self):
        network = dict(self.identity, status="attached", activePrimary="old-primary", activeReplica="old-replica")
        self.write("network-fence.json", dict(network, account="111111111111"))
        with self.assertRaises(ValueError):
            self.declare([])
        self.write("network-fence.json", network)
        self.declare()
        result = self.package()
        self.assertTrue((Path(result["location"]) / "snapshot/network-fence.json").is_file())

    def test_log_is_omitted_without_claiming_review(self):
        (self.run / "app-deploy.log").write_text("fixture log")
        self.declare()
        result = self.package()
        snapshot = Path(result["location"]) / "snapshot"
        self.assertFalse((snapshot / "app-deploy.log").exists())
        self.assertIn("no automatic log review is claimed", (snapshot / "summary.md").read_text())

    def test_tampered_closeout_and_missing_t10_refused(self):
        original = self.declare()
        for key, value in (("t10At", None), ("t10At", "2026-10-21T00:49:00Z"),
                           ("reviewed", False), ("approvalRef", ""),
                           ("originalT0EvidenceRef", "changed"), ("t9Ref", "changed")):
            with self.subTest(key=key, value=value):
                self.write("closeout.json", dict(original, **{key: value}))
                with self.assertRaises(ValueError):
                    self.package()
        self.assertFalse((self.run / "evidence-package.json").exists())

    def test_archive_failure_cleans_private_staging(self):
        self.declare()
        with patch.object(MODULE.tarfile, "open", side_effect=OSError("fixture archive failure")):
            with self.assertRaises(OSError):
                self.package()
        self.assertEqual(list((self.root / "evidence/bb3-packages").iterdir()), [])
        self.assertFalse((self.run / "evidence-package.json").exists())

    def test_destination_symlink_refused(self):
        self.declare()
        destination = self.root / "evidence/bb3-packages"
        destination.symlink_to(self.root / "outside")
        with self.assertRaises(ValueError):
            self.package()

    def test_receipt_and_closeout_symlinks_refused(self):
        (self.run / "closeout.json").symlink_to(self.root / "missing")
        with self.assertRaises(ValueError):
            self.declare([])
        (self.run / "closeout.json").unlink()
        self.declare()
        (self.run / "evidence-package.json").symlink_to(self.root / "missing")
        with self.assertRaises(ValueError):
            self.package()


if __name__ == "__main__":
    unittest.main()