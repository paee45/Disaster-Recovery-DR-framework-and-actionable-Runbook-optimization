# 06 — Communication Matrix & Rules

Templates live in [`templates/communications/`](../templates/communications/):

| File | Audience | Channel |
|---|---|---|
| [`01-internal-technical-chat.md`](../templates/communications/01-internal-technical-chat.md) | SRE, Dev, SecOps, DBA | Slack / MS Teams incident channel |
| [`02-leadership-email.md`](../templates/communications/02-leadership-email.md) | Executives, Service Owners, Account/Customer Success leads | Email + exec chat channel + bridge |
| [`03-supplier-vendor.md`](../templates/communications/03-supplier-vendor.md) | Upstream/downstream suppliers, integration partners, AWS Support/TAM | Email / support case / partner channel |
| [`04-customer-statuspage-email.md`](../templates/communications/04-customer-statuspage-email.md) | Customers / business users | Status page + email (+ in-app banner) |
| [`05-planned-drill-notices.md`](../templates/communications/05-planned-drill-notices.md) | All, for **planned** DR tests / switchovers | Email / status page "scheduled maintenance" |

Each template covers the four lifecycle phases: **[Investigating] → [Failover Initiated] → [Services Restored] → [Post-Mortem / RCA Ready]**.

## 1. Matrix — who is told what, when, by whom

| Audience | DEV | UAT | PROD | Cadence (PROD) | Sender | Approver |
|---|---|---|---|---|---|---|
| Internal technical | Team channel | `#inc-uat-*` channel | `#inc-<id>-dr` channel + bridge | At each phase change + every **15 min** | Scribe / IC | IC |
| Leadership | — | Email only if UAT users are blocked > 4 h | Email + exec channel | Phase change + every **30 min** (SEV1) | Comms lead | IC |
| Suppliers / vendors | — | Only if integration tests are affected | If integrations are affected or need action (pause batch, replay files, IP allow-list for Region B) | Phase change | Comms lead / Integration owner | IC + Service Owner |
| Customers | — | UAT customers / implementation projects (email) | Status page + email to admin contacts | Within **30 min** of impact (or as the SLA says), then every **60 min** | Comms lead | IC + Customer Success lead (+ Legal if data loss/security) |
| Regulators / DPO | — | — | Only if personal data is affected (availability or integrity loss can count as a breach under GDPR, with a 72 h clock) | As legal requires | DPO / Legal | Legal |

## 2. Rules
1. **One voice per audience.** Only the Comms lead posts externally. Engineers do not answer customers directly in tickets during the incident; they link to the status page.
2. **Commit to the next update time, and keep it.** Every message ends with "Next update by HH:MM UTC" (plus a local time zone for regional customers). Send an update even if there is no news.
3. **Say what is known, not why it might have happened.** External messages do not speculate about root cause or blame AWS or suppliers by name, unless the IC/Legal approve.
4. **Data loss wording needs Legal/IC approval.** Use the pre-approved phrasing in the templates. Never write "no data was lost" until reconciliation is complete.
5. **Use environment tags in every subject/first line:** `[PROD]`, `[UAT]`, `[DEV]`, and `[DRILL]` for exercises. **Every drill message starts and ends with `[DRILL] — THIS IS AN EXERCISE`** so a drill is never mistaken for a real incident.
6. **Use time zones correctly.** Write UTC first, then local (e.g. `14:05 UTC / 16:05 CEST`).
7. **Log every message** to `comms/sent-messages.md` in the evidence bundle (the incident platform can do this automatically).
8. **Pre-stage** status page incidents and email lists (distribution lists per env and per customer tier) **before** they are needed. Find out during drills who owns the lists.

## 3. Severity → comms mapping

| Severity | Description | Customer comms | Leadership |
|---|---|---|---|
| SEV1 | PROD down / DR failover in progress | Status page **Major outage**, email | Immediately, every 30 min |
| SEV2 | PROD degraded (read-only, slow) | Status page **Degraded performance** | Within 1 h |
| SEV3 | UAT unavailable | UAT customer email | Daily summary |
| SEV4 | DEV | None | None |

## 4. Chat practices (incident channel)
- Name channels predictably: `#inc-YYYYMMDD-prod-rds-dr`. **Pin** the runbook link, the bridge link, the roles and the current status.
- Use a single **status message** that is *edited* (with a timestamp), plus threaded updates. This keeps the channel readable.
- Use slash commands / workflows from the incident tool (`/inc declare`, `/inc role`, `/inc update`) so the timeline is captured automatically.
- Keep decisions in the channel with a fixed prefix (`DECISION:`), so the scribe/tool can parse them for the timeline.
