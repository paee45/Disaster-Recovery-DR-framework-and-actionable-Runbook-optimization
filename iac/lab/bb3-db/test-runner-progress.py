import importlib.util
from pathlib import Path
import unittest
import tempfile
import json
import hashlib
import os
import pty
import select
import shutil
import subprocess
import time


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

    def test_legacy_submission_requires_probe(self):
        with tempfile.TemporaryDirectory() as directory:
            context = self.context(Path(directory))
            records = {"incident.json": dict(self.identity, status="declared", scenario="S3")}
            self.assertEqual(MODULE.recovery_next(records, {}, context), "probe")
            self.assertEqual(MODULE.recovery_next(records, {}, context, []), "P2-S00")
            inventory = [dict(DBInstanceIdentifier="restored", Engine="postgres",
                              TagList=[dict(Key="dr-restore", Value="DR-fixture")])]
            self.assertEqual(MODULE.recovery_next(records, {}, context, inventory), "P2-S02")

    def test_changed_completed_evidence_blocks_but_pending_action_can_update(self):
        with tempfile.TemporaryDirectory() as directory:
            context = self.context(Path(directory))
            ledger = Path(context["ledger"])
            run = ledger / "DR-fixture"
            run.mkdir(parents=True)
            network = dict(self.identity, mode="cutover", status="submitted")
            path = run / "network-fence.json"
            path.write_text(json.dumps(network))
            MODULE.checkpoint(ledger, context, "recovery", "start", "P0-S03")
            path.write_text(json.dumps(dict(network, status="attached")))
            self.assertEqual(MODULE.plan(ledger, context, "recovery")["next"], "P0-S01")
            MODULE.checkpoint(ledger, context, "recovery", "done", "P0-S03")
            path.write_text(json.dumps(dict(network, status="released")))
            with self.assertRaisesRegex(ValueError, "Completed evidence changed"):
                MODULE.plan(ledger, context, "recovery")

    def seed_released_failback(self, root):
        context = self.context(root)
        ledger = Path(context["ledger"])
        run = ledger / "DR-fixture"
        run.mkdir(parents=True)
        network = dict(self.identity, mode="cutover", status="attached",
                       activePrimary="original", activeReplica="original-replica")
        (run / "cutover.json").write_text(json.dumps(self.records["cutover.json"]))
        (run / "network-fence.json").write_text(json.dumps(network))
        MODULE.checkpoint(ledger, context, "recovery", "adopt", "P5")
        self.fence()
        self.records["failback.json"] = dict(self.identity, operation="failback", status="complete",
            source_db="restored", source_replica="restored-replica", db="original", replica="original-replica")
        self.records["network-fence.json"] = dict(network, status="released")
        for name, record in self.records.items():
            (run / name).write_text(json.dumps(record))
        MODULE.checkpoint(ledger, context, "failback", "adopt", "deployment")
        return ledger, context, run

    def test_recovery_handoff_accepts_checkpointed_source_release(self):
        with tempfile.TemporaryDirectory() as directory:
            ledger, context, run = self.seed_released_failback(Path(directory))
            paths = [MODULE.state_path(ledger, context, mode) for mode in ("recovery", "failback")]
            before = [path.read_bytes() for path in paths]
            result = MODULE.plan(ledger, context, "recovery")
            self.assertEqual(result["mode"], "failback")
            self.assertEqual(result["next"], "deployment")
            self.assertEqual([path.read_bytes() for path in paths], before)

    def test_handoff_still_rejects_untracked_network_edits(self):
        with tempfile.TemporaryDirectory() as directory:
            ledger, context, run = self.seed_released_failback(Path(directory))
            path = run / "network-fence.json"
            network = json.loads(path.read_text())
            path.write_text(json.dumps(dict(network, changedAfterCheckpoint=True)))
            with self.assertRaisesRegex(ValueError, "Completed evidence changed.*network-fence"):
                MODULE.plan(ledger, context, "recovery")

    def test_handoff_requires_release_checkpoint_and_matching_source_pair(self):
        with tempfile.TemporaryDirectory() as directory:
            ledger, context, run = self.seed_released_failback(Path(directory))
            failback = MODULE.state_path(ledger, context, "failback")
            failback.unlink()
            with self.assertRaisesRegex(ValueError, "Completed evidence changed.*network-fence"):
                MODULE.plan(ledger, context, "recovery")
            path = run / "network-fence.json"
            network = json.loads(path.read_text())
            path.write_text(json.dumps(dict(network, activePrimary="unrelated-primary")))
            MODULE.checkpoint(ledger, context, "failback", "adopt", "deployment")
            with self.assertRaisesRegex(ValueError, "Completed evidence changed.*network-fence"):
                MODULE.plan(ledger, context, "recovery")

    def test_handoff_does_not_ignore_other_recovery_evidence_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            ledger, context, run = self.seed_released_failback(Path(directory))
            path = run / "cutover.json"
            cutover = json.loads(path.read_text())
            path.write_text(json.dumps(dict(cutover, changedDuringFailback=True)))
            MODULE.checkpoint(ledger, context, "failback", "adopt", "deployment")
            with self.assertRaisesRegex(ValueError, "Completed evidence changed.*cutover"):
                MODULE.plan(ledger, context, "recovery")


class RunnerInteractionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.here = self.root / "iac/lab/bb3-db"
        self.here.mkdir(parents=True)
        source = Path(__file__).parent
        for name in ("bb3-run.sh", "bb3-prompt.sh", "bb3-wait.py", "runner-progress.py", "closeout.py", "secret-endpoints.py"):
            shutil.copyfile(source / name, self.here / name)
        (self.root / "iac/sandbox.env").write_text(
            "TF_VAR_account_id=000000000000\nTF_VAR_aws_profile=lab_sandbox\nTF_VAR_region=ap-southeast-1\n"
            "ENV=uat\nBB3_DR_ID=DR-fixture\nBB3_SOURCE_PRIMARY_ID=original\nBB3_SOURCE_REPLICA_ID=original-replica\n"
            "BB3_RESTORE_TARGET_PRIMARY_ID=restored\nBB3_RESTORE_TARGET_REPLICA_ID=restored-replica\n"
            "BB3_SNAPSHOT_ID=snapshot-fixture\n")
        fixture = ProgressTests()
        fixture.setUp()
        self.context = fixture.context(self.root)
        self.context.update(t0At="", t0Ref="", configDigest=hashlib.sha256(
            (self.root / "iac/sandbox.env").read_bytes()).hexdigest())
        self.ledger = Path(self.context["ledger"])
        self.run = self.ledger / "DR-fixture"
        self.run.mkdir(parents=True)
        stubs = self.root / "stubs.bash"
        stubs.write_text('''git() { return 0; }
aws() {
  case "$*" in
    *"sts get-caller-identity"*) echo 000000000000 ;;
    *"rds describe-db-instances"*) echo '{"DBInstances":[]}' ;;
    *"rds wait db-instance-available"*) return 0 ;;
    *) echo 'REFUSED unexpected mock AWS call' >&2; return 97 ;;
  esac
}
bash() {
  local helper="${1##*/}"
  shift
  printf 'MOCK_STEP %s' "$helper"
  printf ' <%s>' "$@"
  printf '\\n'
  [[ "$helper" != "${TEST_STOP_HELPER:-}" ]]
}
''')
        self.environment = os.environ.copy()
        for key in list(self.environment):
            if key.startswith("BB3_") or key in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "TEST_STOP_HELPER"):
                self.environment.pop(key, None)
        self.environment.update(BASH_ENV=str(stubs), TERM="xterm", NO_COLOR="", AWS_EC2_METADATA_DISABLED="true")

    def run_terminal(self, arguments, answer="", stop=None):
        master, slave = pty.openpty()
        environment = dict(self.environment)
        if stop:
            environment["TEST_STOP_HELPER"] = stop
        child = subprocess.Popen(["bash", str(self.here / "bb3-run.sh"), "S3", *arguments],
                                 stdin=slave, stdout=slave, stderr=slave, env=environment)
        os.close(slave)
        output = bytearray()
        sent = False
        deadline = time.monotonic() + 25
        try:
            while time.monotonic() < deadline:
                ready, _, _ = select.select([master], [], [], 0.2)
                if ready:
                    try:
                        content = os.read(master, 65536)
                    except OSError:
                        break
                    if not content:
                        break
                    output.extend(content)
                    if not sent and b"Continue from the suggested action?" in output:
                        os.write(master, (answer + "\n").encode())
                        sent = True
                if child.poll() is not None and not ready:
                    break
            if child.poll() is None:
                try:
                    child.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    child.kill()
                    self.fail("Resume interaction timed out: " + output.decode(errors="replace"))
            return child.wait(), output.decode(errors="replace")
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()
            os.close(master)

    def seed_recovery(self, step="P3-S01"):
        MODULE.checkpoint(self.ledger, self.context, "recovery", "adopt", step)

    def seed_failback(self):
        fixture = ProgressTests()
        fixture.setUp()
        for name, record in fixture.records.items():
            (self.run / name).write_text(json.dumps(record))
        return fixture

    def test_enter_continues_recovery_without_discovery_or_restore(self):
        self.seed_recovery()
        exit_code, output = self.run_terminal([])
        self.assertEqual(exit_code, 0, output)
        self.assertIn("Suggested continuation: P3-S01", output)
        self.assertIn("MOCK_STEP fence-confirm.sh", output)
        self.assertIn("MOCK_STEP closeout.sh <package>", output)
        self.assertNotIn("MOCK_STEP discover-env.sh", output)
        self.assertNotIn("MOCK_STEP restore-drill.sh", output)

    def test_cancel_does_not_run_steps_or_change_checkpoint(self):
        self.seed_recovery()
        path = MODULE.state_path(self.ledger, self.context, "recovery")
        before = path.read_bytes()
        exit_code, output = self.run_terminal([], answer="n")
        self.assertEqual(exit_code, 0, output)
        self.assertNotIn("MOCK_STEP", output)
        self.assertEqual(path.read_bytes(), before)

    def test_numeric_rto_policy_change_preserves_checked_resume(self):
        self.seed_recovery()
        config = self.root / "iac/sandbox.env"
        original = config.read_text()
        path = MODULE.state_path(self.ledger, self.context, "recovery")
        before = path.read_bytes()
        for target in ("60", "45", "30", "45.5"):
            with self.subTest(target=target):
                config.write_text(original + f"export BB3_RTO_TARGET_MIN={target}\n")
                exit_code, output = self.run_terminal([], answer="n")
                self.assertEqual(exit_code, 0, output)
                self.assertIn("Suggested continuation: P3-S01", output)
                self.assertNotIn("MOCK_STEP", output)
                self.assertEqual(path.read_bytes(), before)

    def test_other_config_changes_still_refuse_resume(self):
        self.seed_recovery()
        config = self.root / "iac/sandbox.env"
        original = config.read_text()
        for added in ("export BB3_DOCKER_STACK_NAME=changed\n",
                      "export BB3_RTO_TARGET_MIN=60; export BB3_DOCKER_STACK_NAME=changed\n"):
            with self.subTest(added=added):
                config.write_text(original + added)
                exit_code, output = self.run_terminal([])
                self.assertEqual(exit_code, 2, output)
                self.assertIn("configDigest", output)
                self.assertNotIn("MOCK_STEP", output)

    def test_literal_failback_placeholder_has_actionable_error(self):
        exit_code, output = self.run_terminal(["--failback", "{{COMPLETED_CUTOVER_DR_ID}}"])
        self.assertEqual(exit_code, 2, output)
        self.assertIn("actual DR- run ID", output)
        self.assertNotIn("MOCK_STEP", output)

    def test_noninteractive_resume_refuses_without_mutations(self):
        self.seed_recovery()
        result = subprocess.run(["bash", str(self.here / "bb3-run.sh"), "S3"], stdin=subprocess.DEVNULL,
                                capture_output=True, text=True, env=self.environment)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("Interactive confirmation required", result.stderr)
        self.assertNotIn("MOCK_STEP", result.stdout)

    def test_interrupted_failback_retries_fence_and_prints_main_command(self):
        self.seed_failback()
        exit_code, output = self.run_terminal(["--failback", "DR-fixture"], stop="fence-confirm.sh")
        self.assertNotEqual(exit_code, 0)
        self.assertIn("Suggested continuation: fence", output)
        self.assertIn("Stopped at P3-S01 (fence)", output)
        self.assertIn("S3 --failback DR-fixture", output)
        self.assertNotIn("<--apply>", output)

    def test_plain_main_command_offers_existing_failback_continuation(self):
        fixture = self.seed_failback()
        fixture.fence()
        for name, record in fixture.records.items():
            (self.run / name).write_text(json.dumps(record))
        exit_code, output = self.run_terminal([])
        self.assertEqual(exit_code, 0, output)
        self.assertIn("Saved failback progress for run: DR-fixture", output)
        self.assertIn("Suggested continuation: endpoints", output)
        self.assertIn("MOCK_STEP secret-endpoints.sh <--failback> <DR-fixture> <--apply>", output)
        self.assertNotIn("MOCK_STEP discover-env.sh", output)


if __name__ == "__main__":
    unittest.main()