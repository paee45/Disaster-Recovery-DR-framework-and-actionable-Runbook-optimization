# Internal leadership — Email (+ exec chat cross-post)

**To:** `dr-leadership-{{env}}@` (CTO/VP Eng, Service Owner, Head of Customer Success, Head of Support, Security lead; Legal/DPO **only if data loss/security**)
**From:** Comms lead on behalf of the IC · **Cadence:** PROD SEV1 every 30 min; UAT only if UAT is blocked > 4 h · **DEV: not sent**
**Style:** business impact first, decisions needed, no jargon. Each email is ≤ 12 lines in the main body.

---

### 1. [Investigating]
**Subject:** `[{{ENV}}][SEV{{n}}][Investigating] {{SERVICE}} unavailable — DR assessment in progress`
```
Summary: Since {{hh:mm}} UTC, {{SERVICE}} is {{unavailable / degraded}} for {{all / segment}} customers
due to a failure of the primary database in {{region}}.

Business impact: {{e.g. customers cannot save plans; read-only views work}}. Customers affected: {{n / all}}.
Contractual exposure: {{SLA x% — breach after yy min}}.

What we are doing: The incident team (IC: {{name}}) is assessing the recovery option ({{promote standby copy | restore from backup}}).
Decision expected by {{hh:mm}} UTC. Estimated data loss if we fail over: {{≈x seconds / none}}.

Decision needed from you: {{None at this time | Approval to accept up to x min of data loss — reply / join bridge}}

Customer communication: status page posted at {{hh:mm}} UTC.
Next update: {{hh:mm}} UTC · Bridge: {{link}}
```

### 2. [Failover Initiated]
**Subject:** `[{{ENV}}][SEV{{n}}][Recovery Initiated] {{SERVICE}} — {{switching to standby database | restoring data to <time>}}`
```
Decision: At {{hh:mm}} UTC we started {{promotion of the standby database | a restore to <time>}} (approved by {{names}}).
Expected restoration: {{hh:mm}} UTC (based on drill performance of {{x}} min).
Data: {{No data loss expected (planned switchover) | Up to ≈{{x}} seconds of transactions before {{hh:mm}} UTC
may need re-entry or reconciliation; we will confirm after recovery.}}
Risks: {{e.g. reduced capacity for first 30 min; integrations may need replay}}.
Next update: {{hh:mm}} UTC
```

### 3. [Services Restored]
**Subject:** `[{{ENV}}][SEV{{n}}][Restored] {{SERVICE}} operating normally on the recovered database`
```
{{SERVICE}} was restored at {{hh:mm}} UTC. Total customer impact: {{x}} min (target RTO {{y}} min).
Data: {{no loss | ≈x s of transactions under reconciliation — owner {{name}}, ETA {{date}}}}.
Current state: full capacity. Resilience is temporarily reduced ({{no read replica / single-AZ}}) until the
normalisation change on {{date}} (separate change and notice).
Follow-ups: PIR on {{date}}; customer RCA by {{date}} (per contract: {{x}} business days).
```

### Variant — data restore (S3/S4), use in [Recovery Initiated] and [Restored]
```
Data impact: To remove {{the faulty change / damaged data}}, we are restoring the database to {{hh:mm}} UTC.
Changes made by customers between {{hh:mm}} and {{hh:mm}} UTC are not in the restored database. We have preserved
them separately and are assessing which can be re-applied ({{owner}}, ETA {{date}}). Customer wording approved by Legal/CS.
Regulatory: DPO informed {{yes/no}} (integrity/availability loss of personal data may be notifiable).
```

### 4. [Post-Mortem / RCA Ready]
**Subject:** `[{{ENV}}][PIR] {{SERVICE}} DR event {{DR_ID}} — summary and actions`
```
Timeline: impact {{T0}} → decision {{T2}} → restored {{T9}} (RTO {{x}} min vs {{y}} target; RPO {{z}} s vs {{w}}).
Root cause (summary): {{one paragraph}}
What went well: {{2 bullets}} · What we will improve: {{3 bullets with owners/dates}}
Customer RCA: {{link}} (sent {{date}}) · Full PIR: {{link}} · Evidence (audit): {{s3 link}}
Budget/decisions requested: {{e.g. cross-region backup copy / replica — est. cost x/month, closes regional-outage gap}}
```
