# 01 — Reference Architecture

## 1. Topology per environment

```
 DEV                                UAT                                     PROD
 ───                                ───                                     ────
 EKS eks-dev (ns app)               EKS eks-uat (ns app)                    EKS eks-prod (ns app, pods spread over AZs)
   ESO → Secret db-creds              ESO → db-creds / db-creds-ro            ESO → db-creds / db-creds-ro
   Reloader                           Reloader (HA)                           Reloader (HA)
        │                                  │             │                         │              │
        ▼                                  ▼             ▼                         ▼              ▼
 RDS PG app-pg-dev                  RDS PG app-pg-uat ══► app-pg-uat-       RDS PG app-pg-prod ══► app-pg-prod-
 (single-AZ)                        (single-AZ)   async   replica           (Multi-AZ:      async   replica
                                                                             primary ⇄ standby,
 automated backups (PITR)           automated backups (PITR)                 synchronous)
 daily snapshot / AWS Backup        daily snapshot / AWS Backup             automated backups (PITR), AWS Backup
                                                                            daily + cross-account copy (Vault Lock)
```

**Secrets Manager** (per env): `<env>/app/db` (writer endpoint) and `<env>/app/db-ro` (UAT/PROD reader endpoint), with JSON
keys `host`, `port`, `dbname`, `username`, `password` (and optionally `engine`, `dbInstanceIdentifier`). The `host` is the
**RDS instance endpoint**. There is no DNS alias layer.

## 2. The cutover chain (S2/S3/S4)

```
 ┌─────────── AWS ───────────┐          ┌──────────────────────── EKS ────────────────────────┐
 │ promote / restore          │          │                                                     │
 │      ▼                     │          │ ExternalSecret db-creds (refreshInterval 1m;         │
 │ TARGET_DB available        │          │   force-sync annotation = immediate)                 │
 │      ▼                     │  sync    │      ▼                                               │
 │ put-secret-value           │ ───────► │ K8s Secret db-creds (DB_HOST changes)                │
 │ host=<TARGET_DB endpoint>  │          │      ▼                                               │
 │ (AWSPREVIOUS = rollback)   │          │ Stakater Reloader → rolling restart of annotated     │
 └────────────────────────────┘          │ consumers, by dr.example.com/restart-order:           │
                                         │ 1 poolers → 2 APIs → 3 workers (maxUnavailable 0)    │
                                         │      ▼                                               │
                                         │ new pods → TARGET_DB; old pods drain → OLD_DB = 0    │
                                         └─────────────────────────────────────────────────────┘
```

| Component | Practice |
|---|---|
| Secret write | **`SECRET_MODE=k8s` (current default): `dr-secret-cutover.sh apply` patches every host key of the K8s Secret directly and records the change (ledger ConfigMap, change id = DR id); `SECRET_MODE=eso` (target): the rows below.** `dr-secret-cutover.sh apply` or SSM `DR-UpdateDbSecretEndpoint` (eso only): updates `host`/`port`/`dbInstanceIdentifier`, keeps the previous version as `AWSPREVIOUS`, never logs values |
| Password trap | A restored DB (S3/S4) contains role passwords **as of the restore point**. `dr-secret-cutover.sh precheck` tests the login before the switch; `fix-password` resets the role to the current secret value |
| Rotation | Suspend Secrets Manager rotation during the event (it would race with the cutover); re-enable it in CP-03. The RDS rotation Lambda connects to `host`, so after the cutover it rotates the new instance |
| ESO | `refreshInterval: 1m`; the cutover forces a sync with the `force-sync` annotation and verifies `DB_HOST` in the K8s Secret |
| Reloader | `secret.reloader.stakater.com/reload: "db-creds"` on every consumer; `reloadStrategy: annotations` (GitOps-safe), HA (2 replicas). The scripts **verify** that each consumer was actually reloaded (generation bump) and fall back to `kubectl rollout restart` |
| Not covered by Reloader | CronJobs (suspended, then resumed), running Jobs, apps reading Secrets Manager directly via the SDK, unannotated workloads → the inventory lists them |
| Rollout safety | `maxUnavailable: 0`, readiness fails when the DB is unreachable/read-only, liveness independent of the DB |
| Read path | `db-creds-ro` → replica. After S2/S3/S4, temporarily point it at the new primary (the replica is gone or stale) until FB creates a new replica |

## 3. S1 is different: Multi-AZ keeps the endpoint

During an S1 failover, AWS moves the **same endpoint DNS name** to the standby (typically 60–120 s). The secret does not change,
so **Reloader is not triggered**. The application must recover by itself:
- driver/JVM DNS cache TTL ≤ 30 s (`networkaddress.cache.ttl`)
- connection pool validation and `maxLifetime` ≤ 5 min
- readiness drops while the DB is unreachable; liveness does not (no restart storms)
- runbook fallback: an ordered `rollout restart` if errors persist > 3 min after the failover completes

## 4. Fencing (split-brain prevention)

With secret-based cutover the old instance stays reachable, and any not-yet-restarted pod, CronJob or script can write to it.
[CP-04](../runbooks/common/CP-04-fencing-old-instance.md) defines three levels: **F1** read-only default + terminate sessions,
**F2** quarantine security group (no inbound), **F3** stop the instance. Always snapshot the old instance first.

## 5. Backups (the foundation of S3/S4)

| Item | DEV | UAT | PROD |
|---|---|---|---|
| Automated backups (PITR) retention | **7 d** | **7 d** | **7 d** |
| Daily snapshot | RDS automated daily snapshot (7 d) | same | same |
| Cross-account copy (security events) | — | — | **None today** (risk R5; option: AWS Backup copy to a Vault-Locked vault in another account) |
| Retained automated backups on deletion | Recommended on | Recommended on | **Recommended on** (`--no-delete-automated-backups`) + deletion protection |
| Cross-region copy / replica | — | — | **None today**: replica is in the same region (risk R1, accepted) |
| Restore test | Not scheduled (R2) | Not scheduled (R2) | Not scheduled (R2) |
