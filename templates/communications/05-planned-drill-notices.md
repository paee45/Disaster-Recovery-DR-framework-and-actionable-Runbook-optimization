# Planned DR tests, switchovers and failbacks

Every drill message starts and ends with **`[DRILL] — THIS IS AN EXERCISE`** in internal channels.
For customers, a planned switchover is presented as **scheduled maintenance**, not a "disaster".

| When | Audience | Channel | Template |
|---|---|---|---|
| T−10 business days (PROD) / T−5 (UAT) | Customers (PROD: all; UAT: implementation projects) | Status page scheduled maintenance + email | A |
| T−5 business days | Suppliers / partners with integrations | Email | B |
| T−2 days | Internal (all eng, support, CS) | Chat + email | C |
| T−0 start / end | All above | Status page auto-start/complete + chat | C (start/end lines) |
| T+5 business days | Leadership + GRC | Email with the drill report | D |

### A. Customer — scheduled maintenance
```
Subject: [{{ENV}}] Scheduled maintenance — {{SERVICE}} — {{date}} {{hh:mm}}–{{hh:mm}} UTC
As part of our regular business-continuity testing, we will perform planned maintenance on {{SERVICE}}.
Window: {{date}}, {{hh:mm}}–{{hh:mm}} UTC ({{local time}}). Expected impact: up to {{x}} minutes of
{{unavailability / read-only access}} within this window. No action is required and no data impact is expected.
Status updates: {{status page link}}.
```

### B. Supplier / partner
```
Subject: [{{ENV}}] Planned maintenance — {{SERVICE}} integrations — {{date}}
Window: {{…}} UTC. During up to {{x}} minutes, {{inbound processing pauses / API returns 503 — please retry}}.
Endpoints do not change. {{Traffic may originate from IPs {{list}} — please confirm allow-listing by {{date}}.}}
Contact during the window: {{phone/email}}.
```

### C. Internal (chat)
```
[DRILL] — THIS IS AN EXERCISE
📅 {{ENV}} DR drill {{DR_ID}} — {{date}} {{hh:mm}} UTC — RB-{{ENV}}-{{S2|S3|S4}} v{{x}} ({{planned drill | unplanned simulation}})
Roles: IC @{{}} · Exec @{{}} · DBA @{{}} · Comms @{{}} · Scribe @{{}} · Observers: @{{auditor/GRC}}
Change: {{CHG}} · Abort criteria: customer SLO alarm {{name}} / IC call · Freeze: deploys {{window}}
[DRILL] — THIS IS AN EXERCISE
```

### D. Leadership / GRC — drill result
```
Subject: [{{ENV}}][DRILL RESULT] {{SERVICE}} DR drill {{DR_ID}} — RTO {{x}} min / RPO {{y}} s
Result: {{PASS / PASS with findings / FAIL}} vs targets RTO {{a}} / RPO {{b}}.
Trend vs last drill: RTO {{↓/↑ x min}}, manual steps {{↓ n}}.
Findings: {{n}} ({{critical}} critical) — top 3: {{…}}. Report + evidence: {{links}}.
```
