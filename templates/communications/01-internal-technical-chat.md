# Internal technical — Chat (Slack / MS Teams)

**Channel:** `#inc-{{YYYYMMDD}}-{{env}}-rds-dr` · **Sender:** Scribe / IC · **Cadence:** each phase change + every 15 min (PROD), 30 min (UAT)
Use **one pinned status message that is edited**, plus threaded updates. Put `[DRILL] — THIS IS AN EXERCISE` first and last for drills.

Environment variants:
| Env | Who is tagged | Notes |
|---|---|---|
| DEV | `@team-{{service}}` | Short form only. No bridge needed |
| UAT | `@sre-oncall @dba @team-{{service}} @qa-lead` | Mention affected UAT customers/projects |
| PROD | `@sre-oncall @dba @secops @team-{{service}} @incident-commanders` | Bridge mandatory; exec channel gets the cross-post |

---

### 📌 Pinned status (edit in place)
```
🔴 [{{ENV}}] SEV{{n}} — {{SERVICE}} database DR | Status: {{INVESTIGATING|FAILOVER IN PROGRESS|RESTORED|MONITORING}}
IC: @{{ic}} · Executor: @{{exec}} · DBA: @{{dba}} · Comms: @{{comms}} · Scribe: @{{scribe}}
Bridge: {{link}} · Runbook: RB-DR-RDS-001 v{{x}} {{link}} · Incident: {{ticket}}
Impact start (T0): {{hh:mm}} UTC · Current phase: {{P1..P5}} / step {{Pn-Sxx}} · Next update: {{hh:mm}} UTC
Last updated: {{hh:mm}} UTC
```

### 1. [Investigating]
```
🔍 [{{ENV}}] [Investigating] {{SERVICE}} — primary DB {{PRIMARY_DB}} ({{PRIMARY_REGION}}) unreachable / degraded since {{T0}} UTC.
• Impact: {{e.g. 100% of write requests failing; reads degraded}}
• Signals: {{alarm name}}, synthetic {{name}} failing, AWS Health: {{status/none}}
• Actions now: P1 pre-flight running (replica lag {{x}}s, DR EKS {{ok}}). In-region HA: {{status}}
• Decision G1 (failover vs wait) expected by {{hh:mm}} UTC
• Please: no ad-hoc changes to DB/DNS/secrets/Argo — all actions go through the IC.
Next update: {{hh:mm}} UTC
```
*DEV short form:* `🔍 [DEV] {{SERVICE}} DB down since {{T0}}. Testing DR automation; no action needed from you. Update in 30 min.`

### 2. [Failover Initiated]
```
🔁 [{{ENV}}] [Failover Initiated] DECISION: G1 GO at {{T2}} — approved by {{IC}}, {{Service Owner}}{{, exec}}.
• Estimated data loss: {{≈x s | 0 (planned)}} (last replayed commit {{ts}}, LSN {{lsn}})
• Fencing: traffic {{done}}, Region A writers {{scaled 0 | unreachable – waiver}}, old primary SG {{revoked | waiver}}
• Executing: SSM {{execution-id}} — promote {{DR_DB}} in {{DR_REGION}} → CNAME {{DB_CNAME}} → EKS rollout
• Freeze: deployments, migrations, batch jobs FROZEN until further notice
Next update: {{hh:mm}} UTC (or at G2/G3)
```

### 3. [Services Restored]
```
✅ [{{ENV}}] [Services Restored] {{SERVICE}} serving from {{DR_REGION}} since {{T9}} UTC.
• DB {{DR_DB}} promoted (writable at {{T5}}), CNAME switched {{T6}}, rollouts complete {{T7}}, traffic {{T8}}
• Business RTO: {{T9−T0}} min (target {{x}}) · RPO actual: {{x}} s (target {{y}})
• Synthetics green x3; error rate {{x}}%, p95 {{x}} ms
• Still open: Multi-AZ conversion {{status}}, rotation re-enabled {{y/n}}, GitOps synced {{y/n}}
• Freeze remains on schema changes until {{time}}. Monitoring for {{2 h}}.
• ⚠ No cross-region DR protection until failback (change {{CHG}}) is complete.
```

### 4. [Post-Mortem / RCA Ready]
```
📝 [{{ENV}}] [PIR Ready] {{SERVICE}} DR event {{DR_ID}}
• PIR: {{link}} · Evidence: s3://{{bucket}}/{{prefix}} (manifest sha256 {{hash}})
• RTO {{x}} min / RPO {{y}} s vs targets {{a}}/{{b}} — {{met / not met}}
• Top 3 learnings: 1) {{}} 2) {{}} 3) {{}}
• Action items: {{n}} created ({{Jira filter link}}). Runbook v{{x+1}} PR: {{link}}
• Failback scheduled: {{date}} (change {{CHG}})
```
