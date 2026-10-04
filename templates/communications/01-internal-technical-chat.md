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
Bridge: {{link}} · Runbook: RB-{{ENV}}-{{S1|S2|S3|S4}} v{{x}} {{link}} · Incident: {{ticket}}
Impact start (T0): {{hh:mm}} UTC · Current phase: {{P1..P5}} / step {{Pn-Sxx}} · Next update: {{hh:mm}} UTC
Last updated: {{hh:mm}} UTC
```

### 1. [Investigating]
```
🔍 [{{ENV}}] [Investigating] {{SERVICE}} — primary DB {{PRIMARY_DB}} {{unreachable / degraded / data issue}} since {{T0}} UTC.
• Impact: {{e.g. 100% of write requests failing; reads degraded}}
• Signals: {{alarm name}}, synthetic {{name}} failing, AWS Health: {{status/none}}
• Actions now: pre-flight running (replica lag {{x}}s | PITR window {{from–to}}). Multi-AZ failover: {{in progress / none / n/a}}
• Decision G1 (scenario S2/S3/S4 + data loss) expected by {{hh:mm}} UTC
• Please: no ad-hoc changes to the DB, DB secrets or Argo — all actions go through the IC.
Next update: {{hh:mm}} UTC
```
*S1 (PROD Multi-AZ, auto-recovered) short form:* `ℹ️ [PROD] {{SERVICE}} DB Multi-AZ failover {{hh:mm}}–{{hh:mm}} UTC (AWS automatic, RPO 0). App errors for {{x}} min, now normal. No action needed; post-event checks running (RB-PROD-S1).`

*DEV short form:* `🔍 [DEV] {{SERVICE}} DB down/restoring since {{T0}} (RB-DEV-{{S3|S4}}). DEV data after {{snapshot/restore time}} will be lost. Update in 30 min.`

### 2. [Failover Initiated]
```
🔁 [{{ENV}}] [Failover Initiated] DECISION: G1 GO at {{T2}} — scenario {{S2 promote | S3 snapshot <id> | S4 PITR to <ts> mode A/B}} — approved by {{names}}.
• Estimated data loss: {{≈x s (replica lag) | writes after <snapshot/restore time>}}
• Fencing old instance {{OLD_DB}}: {{F1 read-only | F2 quarantine SG | waiver: reason}}
• Executing: SSM {{execution-id}} — {{promote | restore}} → {{TARGET_DB}} → secret {{SECRET_ID}} update → ESO → Reloader rollouts
• Expect: pods of all DB consumers will roll (Reloader) after the cutover gate G3; CronJobs suspended
• Freeze: deployments, migrations, batch jobs FROZEN until further notice
Next update: {{hh:mm}} UTC (or at G2/G3)
```

### 3. [Services Restored]
```
✅ [{{ENV}}] [Services Restored] {{SERVICE}} running on {{TARGET_DB}} since {{T9}} UTC.
• DB writable {{T5}}, secret updated {{T6}}, Reloader rollouts complete {{T7}}; 0 app sessions on {{OLD_DB}}
• Business RTO: {{T9−T0}} min (target {{x}}) · RPO actual: {{x}} s (target {{y}})
• Synthetics green x3; error rate {{x}}%, p95 {{x}} ms
• Still open: Multi-AZ {{status}}, new read replica {{status}}, rotation {{off}}, parity/IaC {{status}}, CronJobs {{resumed?}}
• Freeze remains on schema changes until {{time}}. Monitoring for {{2 h}}.
• ⚠ Reduced protection until RB-{{ENV}}-FB-{{…}} (change {{CHG}}) is complete.
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
