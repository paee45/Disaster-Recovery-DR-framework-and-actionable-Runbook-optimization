import importlib.util
from pathlib import Path
import unittest
import tempfile
import json


SPEC = importlib.util.spec_from_file_location("runner_progress", Path(__file__).with_name("runner-progress.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ProgressTests(unittest.TestCase):
    def setUp(self):
        self.identity = dict(runId="DR-fixture", account="000000000000", region="ap-southeast-1")
        self.records = {"cutover.json": dict(self.identity, operation="cutover", status="complete",
            db="restored", replica="restored-replica", source_db="original", source_replica="original-replica",
            oldHost="original.example.invalid", oldReplicaHost="original-replica.example.invalid",
            newHost="restored.example.invalid")}

    def fence(self):
        self.records["failback-network-fence.json"] = dict(self.identity, mode="failback", status="attached",
            activePrimary="restored", activeReplica="restored-replica")
        self.records["failback-fence.json"] = dict(self.identity, mode="failback", status="owner-confirmed",
            activePrimary="restored", activeReplica="restored-replica", returnPrimary="original",
            returnReplica="original-replica", appOwner="app-owner", fenceVerified=True, existingSessionsClosed=True)

    def test_partial_fence_is_not_completion(self):
        self.assertEqual(MODULE.failback_next(self.records, self.identity), "fence")
        self.fence()
        self.records["failback-fence.json"]["existingSessionsClosed"] = False
        self.assertEqual(MODULE.failback_next(self.records, self.identity), "fence")

    def test_completed_actions_suggest_next_distinct_action(self):
        self.fence()
        self.assertEqual(MODULE.failback_next(self.records, self.identity), "endpoints")
        self.records["failback.json"] = dict(self.identity, operation="failback", status="complete",
            source_db="restored", source_replica="restored-replica", db="original", replica="original-replica")
        self.assertEqual(MODULE.failback_next(self.records, self.identity), "release")
        self.records["network-fence.json"] = dict(self.identity, mode="cutover", status="released",
            activePrimary="original", activeReplica="original-replica")
        self.assertEqual(MODULE.failback_next(self.records, self.identity), "deployment")
        self.records["failback-app-deploy.json"] = dict(self.identity, operation="failback", status="owner-confirmed",
            mode="manual", servicesConverged=True, appOwner="app-owner", primaryHost="original.example.invalid",
            replicaHost="original-replica.example.invalid", evidenceRef="deploy-ref")
        self.assertEqual(MODULE.failback_next(self.records, self.identity), "health")
        self.records["failback-app-health.json"] = dict(self.records["failback-app-deploy.json"],
            healthVerified=True, evidenceRef="health-ref")
        self.assertEqual(MODULE.failback_next(self.records, self.identity), "signoff")

    def test_wrong_run_is_refused(self):
        with self.assertRaises(ValueError):
            MODULE.failback_next(self.records, dict(self.identity, runId="DR-other"))

    def context(self, root):
        root = root.resolve()
        return dict(self.identity, root=str(root), ledger=str(root / "evidence/bb3-secret-endpoints"),
                    environment="uat", primary="original", replica="original-replica", snapshot="snapshot-fixture",
                    targetPrimary="restored", targetReplica="restored-replica")

    def test_every_recovery_checkpoint_suggests_first_incomplete_step(self):
        with tempfile.TemporaryDirectory() as directory:
            context = self.context(Path(directory))
            for index, step in enumerate(MODULE.RECOVERY):
                with self.subTest(step=step):
                    state = dict(completed=MODULE.RECOVERY[:index], pending=step)
                    expected = "probe" if step in ("P2-S01", "P2-S05") else step
                    self.assertEqual(MODULE.recovery_next({}, state, context), expected)

    def test_pending_submission_checks_owned_target_before_waiter(self):
        with tempfile.TemporaryDirectory() as directory:
            context = self.context(Path(directory))
            for step, target, waiter in (("P2-S01", "restored", "P2-S02"),
                                          ("P2-S05", "restored-replica", "P2-S06")):
                state = dict(completed=[], pending=step)
                self.assertEqual(MODULE.recovery_next({}, state, context, []), step)
                instance = dict(DBInstanceIdentifier=target, Engine="postgres",
                                ReadReplicaSourceDBInstanceIdentifier="restored",
                                TagList=[dict(Key="dr-restore", Value="DR-fixture")])
                self.assertEqual(MODULE.recovery_next({}, state, context, [instance]), waiter)
                instance["TagList"] = []
                with self.assertRaisesRegex(ValueError, "not proven"):
                    MODULE.recovery_next({}, state, context, [instance])

    def test_checkpoint_scope_atomic_update_and_adoption(self):
        with tempfile.TemporaryDirectory() as directory:
            context = self.context(Path(directory))
            ledger = Path(context["ledger"])
            MODULE.checkpoint(ledger, context, "recovery", "start", "P0-S01")
            MODULE.checkpoint(ledger, context, "recovery", "done", "P0-S01")
            result = MODULE.plan(ledger, context, "recovery")
            self.assertEqual(result["next"], "P0-S02")
            with self.assertRaisesRegex(ValueError, "differs"):
                MODULE.plan(ledger, dict(context, targetPrimary="another-target"), "recovery")
            MODULE.checkpoint(ledger, context, "recovery", "adopt", "P2-S02")
            self.assertEqual(MODULE.plan(ledger, context, "recovery")["next"], "P2-S02")
            path = MODULE.state_path(ledger, context, "recovery")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(path.read_text())["completed"][-1], "P2-S01")

    def test_symlink_checkpoint_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            context = self.context(Path(directory))
            ledger = Path(context["ledger"])
            ledger.mkdir(parents=True)
            outside = Path(directory) / "outside.json"
            outside.write_text("{}")
            MODULE.state_path(ledger, context, "recovery").symlink_to(outside)
            with self.assertRaises(ValueError):
                MODULE.checkpoint(ledger, context, "recovery", "start", "P0-S01")


if __name__ == "__main__":
    unittest.main()