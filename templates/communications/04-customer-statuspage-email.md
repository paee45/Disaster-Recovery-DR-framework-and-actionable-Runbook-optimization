# External customers / business users — Status page + Email

**Channels:** Status page (primary, public or per-customer), email to customer admin/key contacts, optional in-app banner.
**Sender:** Comms lead · **Approver:** IC + Customer Success lead (**+ Legal** for any data-loss or security wording)
**Cadence (PROD):** first post ≤ 30 min from impact (or SLA), then every 60 min, plus at each phase change.

| Env | Audience | Channel |
|---|---|---|
| DEV | — | Not sent |
| UAT | Customers in implementation / UAT testing | Email from the project/implementation lead (template below, with the `[UAT]` tag). No public status page |
| PROD | All affected customers | Status page component `{{SERVICE}}` + email to subscribers/admins |

**Wording rules:** plain language, no internal names (regions, instances, vendors), no speculation, no blame. Never say "no data was lost" until reconciliation is signed off.

---

### 1. [Investigating]
**Status page — Major outage / Degraded performance**
```
Investigating — We are aware that {{SERVICE}} is currently {{unavailable / experiencing errors when saving changes}}
for {{some / all}} customers since {{hh:mm}} UTC. Our engineering team is actively investigating and working to restore
service. We will provide an update by {{hh:mm}} UTC.
```
**Email subject:** `[{{ENV}}] {{SERVICE}} service disruption — we are investigating`

### 1b. S1 — brief automatic failover (PROD), only if customer-visible (> 2 min or reported)
```
Resolved — Between {{hh:mm}} and {{hh:mm}} UTC some requests to {{SERVICE}} failed during an automatic switch to
redundant database infrastructure. Service recovered automatically; no data was affected. We apologise for the disruption.
```

### 2. [Failover Initiated]
```
Identified — We have identified an infrastructure issue affecting {{SERVICE}} and are moving the service to our
secondary infrastructure as part of our business continuity procedures. During this time {{SERVICE}} will be
{{unavailable / read-only}}. We expect service to be restored by approximately {{hh:mm}} UTC.
Next update by {{hh:mm}} UTC.
```

### 3. [Services Restored]
*Variant A — no data impact (planned or RPO = 0, confirmed):*
```
Resolved / Monitoring — {{SERVICE}} was fully restored at {{hh:mm}} UTC and is operating normally. No customer
action is required. We are continuing to monitor closely. We apologise for the disruption; a summary of the
incident will be provided by {{date}}.
```
*Variant B — possible data impact (Legal-approved wording):*
```
Monitoring — {{SERVICE}} was restored at {{hh:mm}} UTC. Changes saved between approximately {{hh:mm}} and
{{hh:mm}} UTC may not have been retained. We are verifying this and will contact affected customers directly
with specific details by {{date/time}}. In the meantime, if you made changes in this window, we recommend
reviewing them once you log in.
```

### 4. [Post-Mortem / RCA Ready]
**Email subject:** `[{{ENV}}] Incident summary — {{SERVICE}} disruption on {{date}}`
```
Dear {{Customer}},
On {{date}} between {{hh:mm}} and {{hh:mm}} UTC ({{x}} minutes), {{SERVICE}} was {{unavailable}}.
What happened: {{one or two sentences, customer-level, approved}}.
How we responded: our business-continuity procedure moved the service to secondary infrastructure; service was
restored in {{x}} minutes.
Data: {{No customer data was lost. | {{n}} changes made between hh:mm–hh:mm UTC were affected; we have {{restored /
contacted you about}} them.}}
What we are doing to prevent recurrence: {{2–3 bullets}}.
If you have questions, please contact {{CSM / support link}}.
```

### Planned DR test / switchover notices
See [`05-planned-drill-notices.md`](05-planned-drill-notices.md).
