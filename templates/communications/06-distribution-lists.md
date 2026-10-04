# DR Distribution Lists & Contacts (maintained register)

Owner: Comms lead (`{{name}}`) · Reviewed: SRE lead · Approved: CTO · **Review: every quarter and after every DR event/exercise.**
Classification: Internal (contains contact data; keep personal phone numbers in the on-call tool, not here).

## 1. Channels

| Purpose | Primary | Secondary (if primary is down) | Owner |
|---|---|---|---|
| Incident working channel | `#inc-<date>-<env>-rds` (Slack/Teams) | Bridge call `{{link}}` | IC |
| Internal broadcast (org-wide) | `{{#general-broadcast}}` | Email `{{all-staff@}}` | Comms lead |
| Leadership | `{{#exec-incidents}}` + email `{{dr-leadership@}}` | Phone tree `{{on-call tool}}` | Comms lead |
| Customers | Status page `{{url}}` + email to admin contacts | Account managers' direct email | Comms lead |
| Suppliers / partners | Email per partner (below) | Partner phone / portal | Integration owner |
| AWS | AWS Support case (console/CLI) | TAM / account team `{{contact}}` | IC |

## 2. Internal stakeholder lists

| List | Members (roles) | Used for | Address / channel |
|---|---|---|---|
| DR-CORE | SRE on-call, SRE lead, DBA, Backend lead | Every event/exercise, start → end | `{{}}` |
| DR-LEADERSHIP | CTO, Engineering Director, Head of Product, Head of Support | SEV1/SEV2 PROD; exercise start/end | `{{}}` |
| DR-ORG-BROADCAST | Engineering, Product, Support, Customer-facing teams | Exercise start/end; PROD SEV1 summaries | `{{}}` |
| DR-SUPPORT | Support team leads | Customer-facing impact (to answer tickets with the status page link) | `{{}}` |

## 3. External contacts

| Party | Type | Environments | Contact | Contractual notice | Notes |
|---|---|---|---|---|---|
| `{{Customer A}}` | Customer | PROD (+ UAT if a project is active) | `{{}}` | `{{e.g. 30 min after impact; 10 business days for planned}}` | |
| `{{Partner B}}` | Integration (upstream) | PROD, UAT | `{{}}` | `{{}}` | Resend procedure: `{{}}` |
| `{{Vendor C}}` | Supplier | PROD | `{{}}` | `{{}}` | |
| AWS | Cloud provider | All | Support case | Business support SLA | |

## 4. Change log
| Date | Change | By |
|---|---|---|
