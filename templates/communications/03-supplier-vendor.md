# External suppliers / vendors / partners

**Audiences:**
- **Upstream** (they send us data/files/API calls): ERP/POS data feeds, SFTP partners, identity providers
- **Downstream** (we send to them): integration partners, data warehouses, customer-side connectors
- **Infrastructure vendors**: AWS Support case (Business/Enterprise "Production/Business-critical system down") and your TAM; other SaaS dependencies

**Sender:** Comms lead / Integration owner · **Approver:** IC + Service Owner · **DEV:** not sent · **UAT:** only if partner integration tests are affected
**Rule:** tell partners exactly **what action they need to take** (pause, retry, replay, allow-list new IPs). Share no internal root cause.

> Pre-requisite (do this BEFORE an incident): partner contact list per env with 24×7 contacts, the Region B egress IPs/NAT EIPs
> already allow-listed by partners, and partner SFTP/API endpoints that use stable DNS names rather than regional ones.

---

### 1. [Investigating]
**Subject:** `[{{ENV}}] Service notice — {{SERVICE}} integration disruption ({{ref}})`
```
Hello {{Partner}},
Since {{hh:mm}} UTC our {{SERVICE}} {{PROD/UAT}} environment is experiencing a disruption.
Effect on your integration: {{inbound files/API calls are not being processed | outbound deliveries delayed}}.
Requested action: {{Please keep retrying with your normal backoff — do NOT resend manually | Please pause scheduled
deliveries until our next notice}}.
Next update: {{hh:mm}} UTC. Contact: {{integration on-call email / phone}} (ref {{ref}}).
```

### 2. [Failover Initiated]
```
Update {{hh:mm}} UTC: we are moving {{SERVICE}} to our secondary site. Service endpoints and hostnames do NOT change.
{{If applicable: Traffic will originate from these IPs: {{list}} (already shared on {{date}}) — please confirm they are allowed.}}
Requested action: {{continue pausing | no action}}. Expected restoration: {{hh:mm}} UTC.
```

### 3. [Services Restored]
```
Update {{hh:mm}} UTC: {{SERVICE}} integrations are operating normally again.
Requested action:
 - Inbound: {{resume deliveries | resend files/messages sent between {{T_from}} and {{T_to}} UTC (list attached)}}.
 - Outbound: we will {{re-deliver}} items generated between {{T_from}} and {{T_to}} UTC; please de-duplicate on {{key}}.
Please confirm receipt / any anomalies to {{contact}} by {{time}}.
```

### 4. [Post-Mortem / RCA Ready]
```
Following the disruption on {{date}} (ref {{ref}}), reconciliation is complete: {{summary of replayed/resent items}}.
{{If contractually required: a summary RCA is attached.}} Thank you for your support.
```

### AWS Support case (copy-paste)
```
Severity: {{Business-critical system down}} · Service: RDS (PostgreSQL) · Region: {{eu-west-1}}
Account: {{id}} · Resource: arn:aws:rds:{{region}}:{{acct}}:db:{{PRIMARY_DB}}
Issue: Primary instance unreachable since {{T0}} UTC; Multi-AZ failover {{not triggered / stuck}}. Executing cross-region
DR to {{DR_REGION}}. Ask: (1) ETA for instance/regional recovery, (2) any risk to promoting cross-region replica {{DR_DB}},
(3) preserve primary storage for later data reconciliation.
Contact: {{IC name/phone}} · Bridge: {{link}}
```
