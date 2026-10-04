# 01 — Reference Architecture

## 1. Target topology (warm standby, active/passive)

```
                        Route 53 public zone (app.example.com)
                        failover / ARC routing controls
                                   │
              ┌────────────────────┴─────────────────────┐
              ▼                                          ▼
   ┌─────────── Region A (eu-west-1) PRIMARY ──┐  ┌──────── Region B (eu-central-1) DR ───────┐
   │ ALB/NLB ─► EKS eks-prod-euw1              │  │ ALB/NLB ─► EKS eks-prod-euc1               │
   │            Deployments (N replicas)       │  │            Deployments (scaled to min /    │
   │            ESO ─► K8s Secret db-creds     │  │            HPA, ready to scale)            │
   │            Reloader (rolls on change)     │  │            ESO ─► K8s Secret db-creds      │
   │               │                           │  │            Reloader                        │
   │               ▼                           │  │               │                            │
   │   app-pg.db.prod.internal (CNAME, TTL 30) ─┼──┼───────────────┘  (same private zone,      │
   │               │                           │  │                   both VPCs associated)    │
   │               ▼                           │  │                                            │
   │ RDS PG app-pg-prod-euw1 (Multi-AZ) ═══════╪══╪═► RDS PG app-pg-prod-euc1 (read replica)    │
   │        async streaming replication (WAL)  │  │   (promote = becomes standalone writer)    │
   │                                           │  │                                            │
   │ Secrets Manager prod/app/db (primary) ────┼──┼─► prod/app/db (replica secret)             │
   │ KMS multi-Region key (mrk-…) ─────────────┼──┼─► replica key                              │
   │ ECR ──────────────────────────────────────┼──┼─► ECR (cross-region replication)           │
   └───────────────────────────────────────────┘  └────────────────────────────────────────────┘
                     │                                             │
                     └──► AWS Backup ─► cross-ACCOUNT vault (Vault Lock, compliance) ◄──┘
                     └──► CloudTrail org trail ─► log-archive account (Object Lock)
```

## 2. Database DR option comparison

| Criterion | RDS PostgreSQL cross-region read replica | Aurora PostgreSQL Global Database |
|---|---|---|
| Typical replication lag | Seconds. Can grow under write bursts or large transactions | Typically < 1 s (storage-level) |
| RPO control | Monitor `ReplicaLag` only | `rds.global_db_rpo` parameter can **enforce** a max RPO (it blocks commits on the primary if exceeded) |
| Planned switchover (RPO 0) | Not native. You stop writes, wait for lag = 0, then promote | `switchover-global-cluster` (native, RPO 0) |
| Unplanned failover | `promote-read-replica` (irreversible, replica becomes standalone) | `failover-global-cluster --allow-data-loss` |
| Stable endpoint after failover | You build it (Route 53 private CNAME) | **Global writer endpoint** follows the writer automatically |
| Failback effort | High. Rebuild a new replica in Region A, wait for full sync, then a planned promotion | Low/medium. The old primary rejoins as secondary, then you switch over |
| Promotion time (typical) | Minutes (instance restart). **Measure it** | ~1–2 min for managed failover. **Measure it** |
| Cost | Lower | Higher (I/O, replicated write I/O, Aurora instances) |

**Recommendation:** for T1 with RPO ≤ 5 min and RTO ≤ 1 h, an RDS PG cross-region replica is acceptable *if* the
runbook below is automated and drilled. For T0, or if failback pain is a major issue, move to Aurora Global
Database. The runbook supports both (Aurora commands appear as "Alt-Aurora" lines).

> **Logical corruption (class B) and ransomware (class C) are not covered by replication.** Also enable:
> RDS automated backups with cross-region automated-backup replication (PITR in Region B), plus AWS Backup copies to
> a separate account with **Vault Lock (compliance mode)**.

## 3. Secret and endpoint pattern (removes most manual steps)

**Anti-pattern (common in legacy runbooks):** the secret stores the *instance endpoint*. Failover means
editing the secret by hand, then each team restarts its own pods. This is slow, error-prone and hard to audit.

**Recommended pattern:**

| Layer | Practice |
|---|---|
| Endpoint | The secret's `host` = `app-pg.db.prod.internal` (stable). Failover only changes the CNAME target. Use a short TTL (30 s) and set the JDBC/driver DNS cache TTL to ≤ 30 s (JVM `networkaddress.cache.ttl=30`). With Aurora Global, use the **global writer endpoint**. |
| Credentials | An app-specific DB user (not master). Its password lives in Secrets Manager, **replicated** to Region B (`replicate-secret-to-regions`). Because the DB is replicated, the same password is valid on the promoted replica. |
| Rotation | Rotation Lambda deployed in **both** regions. **Suspend rotation during a DR event** (the runbook includes this step) so a rotation does not race with the failover. |
| Sync into EKS | **External Secrets Operator** (`ExternalSecret`, `refreshInterval: 1m`) reads from the *local-region* Secrets Manager endpoint through IRSA / EKS Pod Identity. |
| Restart | **Stakater Reloader** annotation on Deployments. When the K8s Secret changes (for example a credential change), a rolling restart runs automatically. A CNAME switch does **not** change the secret, so the runbook also forces an ordered `kubectl rollout restart` (`dr-eks-rollout.sh restart`). This gives one audited trigger that flushes stale connection pools. |
| Replica secret gotcha | Replica secrets in Region B are **read-only**. If Region A is down and the secret really must change, first run `stop-replication-to-replica` in Region B (this makes it standalone), then write to it. Afterwards, re-establish replication as part of failback. |
| Connection pools | Set pool `maxLifetime` ≤ 5 min and a validation query, and make sure the app fails readiness when the DB is read-only. Then pods heal even without a restart. Restart is the fast path, not the only path. |
| PgBouncer / RDS Proxy | If used, restart/repoint them **before** the app tier. Note: RDS Proxy is regional and bound to a DB, so you need a pre-created proxy in Region B. |

See [`automation/k8s/`](../automation/k8s/) for the manifests.

## 4. Traffic layer

- **Route 53 Application Recovery Controller (ARC)** routing controls are best for the public entry point. Flipping a control is a data-plane operation with 5 regional endpoints, so it works during a regional event. Safety rules (assertion: "at least one region ON") prevent an accidental full outage.
- **ARC Region switch** (if available in your regions) can orchestrate a cross-region recovery plan (Aurora global DB, EKS scaling, Route 53, custom Lambda, manual approval) and keeps an execution history. It is a strong candidate for the T0 orchestrator. Assess it against SSM Automation in [`03`](03-execution-media-and-tooling.md).
- Health checks must test **deep health** (app → DB write path), not just `/healthz` on the load balancer. Otherwise DNS flips back and forth ("flapping").

## 5. Fencing (split-brain prevention)

If Region A is *partially* alive, apps or jobs there may keep writing to the old primary after the replica
is promoted. Use defence in depth, in this order:

1. ARC routing control / Route 53: stop user traffic to Region A.
2. Scale Region A workloads that write to the DB to 0, if the Region A EKS API is reachable (`kubectl scale`, or suspend Argo CD sync first).
3. Isolate the old primary: remove inbound rules from its security group (or apply a deny-all NACL on DB subnets), if the control plane is reachable.
4. The CNAME now points to Region B, so any new connections go to the new primary.
5. Record which fencing steps **could not** be completed. Missing fencing steps are a mandatory input to the data reconciliation in Phase 5.
