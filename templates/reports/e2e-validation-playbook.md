# E2E Post-Restore Validation Playbook — {{SERVICE}} ({{ENV}})

Purpose: the **minimum** checks that prove the service works on the recovered database (CP02 / runbook Phase 4).
Only checks that validate recovery are listed here. Extra checks (e.g. a separate user-login test) are added only if they prove something this list does not.
Owner: Backend lead · Reviewed: SRE lead · Approved: CTO · Keep this page up to date: it is part of the runbook.

## 1. Prerequisites (prepare before any exercise/event)

| Item | Value |
|---|---|
| Admin dashboard URL | `{{https://admin.uat.example.com/...}}` |
| Application test URL | `{{https://app.uat.example.com/...}}` |
| Test account(s) | `{{test user}}` (credentials in the password manager entry `{{name}}`, never in this page) |
| Test hardware / device | `{{e.g. charger model / station ID / test terminal}}` · location `{{lab}}` |
| Designated QR code(s) | `{{QR id / where it is printed or stored}}` |
| Test payment / transaction method | `{{test card / sandbox method}}` |
| Expected processing time | `{{x s}}` |

## 2. Checks (in order; stop at the first failure and escalate)

| # | Check | How | Pass criteria | Evidence (screenshot with visible system clock or command output with UTC time) |
|---|---|---|---|---|
| 1 | Dashboard reachable | Open the admin dashboard URL | Page loads, data visible, no DB error banner | Screenshot incl. clock |
| 2 | One end-to-end transaction | `{{e.g. scan QR on test device → start session → stop → payment}}` | Transaction completes; appears in the dashboard | Transaction ID + screenshot |
| 3 | Transaction persisted in the new DB | `psql "$TARGET_DSN" -c "select id, created_at from {{table}} order by created_at desc limit 1"` | The new transaction ID is present | Command output (UTC) |
| 4 | Background processing | `{{queue/job dashboard}}` | Backlog draining / job processed | Screenshot incl. clock |

Record `dr_mark T9` when check 2 passes for the first time.

## 3. Evidence standard (TICKET-107)
- Every screenshot shows the **system date and time**. Every command output is captured with `dr_run` (it prefixes a UTC timestamp).
- Times are always **UTC** (add the local time in brackets if needed).
- Store everything in the evidence bundle (`app/`), not in personal folders or chat only.
