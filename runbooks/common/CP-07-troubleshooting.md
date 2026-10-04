# CP-07 — Troubleshooting (common failures during DR)

Look up the symptom and apply the fix. Record every use as a deviation (`dr_mark DEVIATION "<what>"`) so the PIR picks it up.

## Environment & tooling

| Symptom | Likely cause | Fix |
|---|---|---|
| `dr-env-check.sh` FAIL: AWS account mismatch | Wrong AWS profile/role | `export AWS_PROFILE=<dr-profile>` or assume `DRExecutorRole`; re-run the check |
| `kube context … missing` | kubeconfig not set up on this machine | `aws eks update-kubeconfig --name <cluster> --alias $EKS_CONTEXT` |
| Command works for one person, fails for another | Different shell variables | Always `source env/<env>.env` + `dr_init`; never edit values inline in commands |
| `Unknown options` / quoting errors in AWS CLI | Hand-typed JSON or lists | Use the scripts (they build arguments as arrays); for lists pass space-separated IDs, not JSON |
| `An error occurred (InvalidParameterCombination)` on restore | Option not valid for this engine/class (e.g. Multi-AZ on an unsupported class, PI on small classes) | Re-run with the profile value overridden, e.g. `MULTI_AZ=false`; note it as a deviation |

## Database (RDS)

| Symptom | Likely cause | Fix |
|---|---|---|
| Restore takes much longer than the budget | Larger DB, storage type, or AWS-side delay | Keep waiting (`dr-restore.sh wait` shows progress); inform the IC; check `aws rds describe-events --source-identifier $RESTORED_DB --source-type db-instance --duration 60` |
| Restored instance has only one SG / the default SG | Settings not passed explicitly | `aws rds modify-db-instance --db-instance-identifier $RESTORED_DB --vpc-security-group-ids <all SGs> --apply-immediately` (the current `dr-restore.sh` copies all SGs from the source) |
| Backup retention 1 day / 0 on the restored DB | Retention is not taken from the snapshot | `./automation/scripts/dr-restore.sh harden $RESTORED_DB` |
| `wait` returns early after promote-read-replica (S2) | Status is still `available` before the promotion starts | Use `dr-verify.sh wait-promoted` (it also checks the source link and `pg_is_in_recovery`) |
| App login fails on the restored DB | Password rotated after the snapshot/restore time | `./automation/scripts/dr-secret-cutover.sh fix-password` (needs `MASTER_SECRET_ID`) |
| `stop-db-instance` fails when simulating an outage | You cannot stop an instance that has a read replica (UAT/PROD) | Simulate the outage with the quarantine SG instead: `./automation/scripts/dr-fence-instance.sh quarantine $PRIMARY_DB` (undo: `restore`) |
| `InvalidDBInstanceState` on modify | The instance is still `modifying`/`backing-up` | `./automation/scripts/dr-restore.sh wait <db>` and retry |
| Restored DB slow for the first minutes | Lazy loading of restored storage blocks | `psql "$TARGET_DSN" -f automation/sql/06-warmup.sql` |
| Multi-AZ failover (S1) not finished after 5 min | AWS-side issue | Open an AWS Support case (template in `03-supplier-vendor.md`); switch to the decision tree (S2) |

## Secret, ESO, Reloader, EKS

| Symptom | Likely cause | Fix |
|---|---|---|
| `TIMEOUT: K8s Secret … host != …` | ESO not syncing (controller down, IAM, wrong key) | `kubectl -n $K8S_NS describe externalsecret $K8S_SECRET`; check the ESO controller logs; check that `K8S_HOST_KEY` matches the template key (e.g. `POSTGRES_DB_HOST`) |
| A workload is `NOT reloaded … manual rollout restart` | Missing Reloader annotation, or Reloader down | The script already restarted it. Afterwards add `secret.reloader.stakater.com/reload: "<secret>"` to that workload (ticket) |
| Pods crash-loop after the cutover | Wrong host/port, SG does not allow EKS → DB, or password mismatch | `kubectl logs`; check the restored DB SGs (parity diff); `dr-secret-cutover.sh precheck` |
| Old DB still has app sessions | Unannotated workload, CronJob/Job, or external client | `dr-verify.sh connections` shows `application_name`; restart that workload; fence the old DB (CP-04) |
| Need to go back | Restored DB is wrong | `./automation/scripts/dr-secret-cutover.sh rollback` (only while the old DB is intact) |
