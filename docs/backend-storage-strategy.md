# Backend Storage Strategy

> Historical decision record, superseded for deployment by
> [Cloudflare Workers + Neon Migration](cloudflare-neon-migration.md) and the
> [deployment runbook](deployment.md). SQLite remains the local source/recovery
> format; hosted preview and production now target Neon Postgres.

Last checked: 2026-06-11

## One-Line Recommendation

Keep local SQLite for development and the first self-hosted build, move to a managed SQLite-compatible service only if a hosted private beta needs near-zero operations, and plan a deliberate Postgres migration before commercial multi-tenant launch.

## Current App Fit

HowMuch is currently a single-hosted Bun API using `bun:sqlite` with WAL enabled. The persistence layer is synchronous and local-file oriented:

- `apps/api/src/db.ts` opens a SQLite file, enables foreign keys and WAL, and applies SQL migrations on startup.
- `LedgerRepository` uses synchronous `db.query(...).get/all/run(...)` and `db.transaction(...)`.
- Writes are mostly small transaction creates/updates from OpenClaw-style bank-alert scripts, mobile quick entry, CSV import, or YNAB migration.
- Reports are SQL scans/groupings over ledger rows, categories, payees, accounts, and split lines.
- The current auth model is a single static bearer token; there is no `users` table, tenant model, session auth, device auth, or per-user access boundary.

That means SQLite is a good storage engine for the app as it exists, but the current application architecture is not ready to become a commercial hosted multi-user service by only swapping database vendors.

## Phase Plan

### Phase 1: Now / Development

Use local SQLite on disk.

Why:

- Zero service cost.
- Fast local iteration with Bun.
- The real imported ledger scale is still personal-finance scale, not database-scale: prior validation imported about 52k active transactions plus accounts, payees, categories, and report history.
- The current schema and repository already use SQLite-specific local APIs.
- Backups are easy to reason about as file snapshots before destructive imports.

Required hardening before relying on it daily:

- Keep `data/*.sqlite` and SQLite WAL/SHM files ignored.
- Keep backup-before-import behaviour.
- Add a documented restore drill: stop API, copy the chosen backup over the active DB, start API, run smoke checks.
- Avoid running more than one API process against the same writable DB file.
- Set `HOWMUCH_API_TOKEN` for anything reachable beyond localhost.

### Phase 2: Private Beta / Small Paid Users

Choose one of two low-cost paths based on product shape.

Recommended if this remains a personal/self-hosted product: small persistent VPS or container host with SQLite plus automated backups.

- Keep the current Bun API and repository.
- Store DB under a persistent volume, for example `/var/lib/howmuch/howmuch.sqlite`.
- Run daily encrypted off-host backups, and preferably WAL-aware replication such as Litestream.
- Put Cloudflare in front for TLS, DNS, and optional tunnel/proxying.
- Treat each hosted user as an isolated deployment or isolated database until there is a proper tenant model.

Recommended if the beta must be centrally hosted with several users but low operations: Turso/libSQL with one database per user.

- It is closer to the current SQLite schema than Postgres.
- It avoids shared-table tenant mistakes while user count is small.
- It gives remote access, managed backups/replication features, and a better path than managing many VPS files manually.
- It still requires a database adapter because the current repository is tied to `bun:sqlite`.

Do not use Cloudflare D1 as the first beta storage target unless the app is also being moved to Workers.

- D1 is SQLite-based and cheap, but its Worker binding API is asynchronous and binding-based.
- The current code expects synchronous `bun:sqlite`.
- A D1 port means adapter work plus async changes through repository, report service, route handlers, importers, tests, and migrations.

### Phase 3: Commercial Scale

Move to Postgres before committing to a shared hosted SaaS model.

Use Postgres/Supabase/Neon when:

- There are real paying customers using the same hosted product.
- You need first-class account/user/session auth.
- You need strong tenant isolation, row-level security, auditability, support workflows, and operational visibility.
- Background imports and report jobs must run independently of request handling.
- You need mature backup, point-in-time recovery, monitoring, migrations, and data-export/delete workflows.

The commercial target should be a shared multi-tenant Postgres database unless there is a strong compliance or enterprise-isolation reason to keep one database per customer.

## Option Comparison

| Option | Fit Now | Private Beta Fit | Commercial Fit | Notes |
| --- | --- | --- | --- | --- |
| SQLite on local disk | Excellent | Good for self-hosted or one-user hosted | Poor for shared SaaS | Cheapest and simplest. Needs disciplined backups and single-writer deployment. |
| SQLite on VPS with Litestream/backups | Good | Good | Limited | Minimal code change. Best bridge if the user is the only real user or beta users get isolated deployments. |
| Turso/libSQL | Medium | Good | Medium | Operationally light and SQLite-shaped. Requires adapter work. One DB per user is a pragmatic beta model. Check current pricing/limits before committing. |
| Cloudflare D1 | Low | Medium | Medium | Cheap and SQLite-shaped, but not compatible with current Bun local-file APIs. Better if the runtime becomes Workers. |
| Supabase Postgres | Low | Medium | Good | More app work now, but strongest path for auth, RLS, admin tooling, and SaaS operations. |
| Neon Postgres | Low | Medium | Good | Strong serverless Postgres option. App must still add tenancy/auth and Postgres-compatible SQL/migrations. |
| Hybrid | Good | Good | Medium | Keep local SQLite for dev/self-hosted, add a DB adapter, then support hosted SQLite or Postgres behind the adapter. |

Current official references checked:

- [Cloudflare D1 pricing](https://developers.cloudflare.com/d1/platform/pricing/) and [limits](https://developers.cloudflare.com/d1/platform/limits/)
- [Turso pricing](https://turso.tech/pricing)
- [Supabase pricing](https://supabase.com/pricing)
- [Neon pricing](https://neon.com/pricing)
- [Litestream](https://litestream.io/)

Pricing changes often; treat exact quotas as a deployment-time check, not as architecture invariants.

Current cost signals from those pages:

- Local SQLite: $0 database cost; the real cost is backup discipline and host reliability.
- SQLite on a small VPS: usually the cost of the VPS plus object storage for backups; no database vendor lock-in.
- Turso: free tier currently lists 100 databases, 5 GB storage, 500 million monthly rows read, 10 million monthly rows written, and 1-day point-in-time restore; the next small paid tier is listed at $4.99/month.
- Cloudflare D1: free tier currently lists 5 million rows read/day, 100k rows written/day, 5 GB account storage, 500 MB maximum database size, and 7-day point-in-time recovery; paid Workers includes larger monthly read/write allowances, 10 GB per database, and 30-day point-in-time recovery.
- Supabase: free tier currently includes 500 MB database size per project; Pro/Team includes 8 GB disk per project before overage, with paid compute/storage economics.
- Neon: free tier currently lists 0.5 GB storage per project and 100 CU-hours monthly per project; the Launch plan is usage-based with a typical small-load example around $15/month.

## SQLite Risk Assessment For HowMuch

SQLite is low risk for the app today.

Strengths:

- The workload is ledger-sized: tens or hundreds of thousands of rows are normal SQLite territory.
- Report queries are simple grouped scans and joins over indexed transaction dimensions.
- Transactions are append/update oriented and low volume.
- Imported history and daily writes benefit from local ACID semantics.
- File-level backup/restore is understandable during development.

Risks:

- A single shared DB file is not an application-level tenant boundary.
- Local SQLite does not solve hosted backups, restore testing, encryption-at-rest policy, support access, or observability by itself.
- The current static bearer token is acceptable for local development but not for external users.
- `server_knowledge` and account-balance recalculation are currently plan-scoped assumptions inside one trusted process; multi-process or multi-user hosting needs careful transaction boundaries and tests.
- `import_id` is indexed but not unique, so idempotency is implemented in application logic rather than enforced by the database.
- Reports that replay history get slower as the ledger grows. Net worth and age of money no longer do: migration `021_account_month_balances.sql` (D1 `0018`) adds `account_month_balances`, a per-account, per-month aggregate maintained by triggers on `transactions`, and `report_cache`, a `server_knowledge`-keyed cache for age of money. Any further report that replays full history has the same risk.
- The synchronous repository API makes D1, remote libSQL, and most hosted database clients a refactor rather than a configuration change.

## Cost-Aware Migration Path

1. Keep SQLite now.
2. Add a storage decision boundary before changing vendors:
   - Introduce a small DB adapter interface around `get`, `all`, `run`, and transactions.
   - Keep the current `bun:sqlite` adapter as the default.
   - Make migrations runnable outside API startup.
3. Before private beta:
   - Decide hosted shape: isolated deployment/database per user, or central multi-tenant.
   - If isolated: keep SQLite and automate backups.
   - If central but tiny: evaluate Turso/libSQL with one DB per user.
   - Avoid shared multi-tenant SQLite tables unless tenancy is fully implemented and tested.
4. Before commercial launch:
   - Migrate to Postgres.
   - Add users, memberships, sessions/device tokens, background jobs, audit logs, export/delete flows, and operational monitoring.
   - Convert SQLite migrations to a Postgres migration tool and run dual-read parity checks on imported ledgers and reports.

## Required Code And Schema Changes

### Before First External Users

- Add `users` or `owners` if any deployment serves more than one person.
- Add a tenant boundary:
  - Isolated beta: one DB/deployment per user is acceptable.
  - Shared beta: add `tenant_id`/`user_id` to all plan-owned tables and enforce it in every query.
- Replace the single static bearer token with real auth for web and scoped tokens for iOS/OpenClaw.
- Add unique constraints for idempotency, for example unique `(plan_id, import_id)` where `import_id` is not null.
- Add backup/restore automation and document recovery time expectations.
- Add a database integrity check to smoke or maintenance scripts.
- Ensure import jobs cannot block normal requests indefinitely.
- Add request/audit logging for writes, imports, deletes, and auth failures.

### Before Commercial Launch

- Move to Postgres or prove that the chosen managed SQLite platform supports the required tenant, backup, restore, support, and compliance model.
- Add `tenant_id` to `plans`, accounts, categories, payees, transactions, subtransactions, import metadata, source events, sync state, and audit tables.
- Enforce tenant isolation in code and database constraints; use RLS if on Supabase/Postgres.
- Add background job tables/workers for YNAB imports, export generation, report precomputation, and account recalculation.
- Add audit logs for all financial-data mutations and support/admin access.
- Add user data export, account deletion, and retention flows.
- Add secrets management for YNAB tokens, mobile tokens, and import credentials.
- Monthly/account aggregate tables now exist (`account_month_balances`, plus `report_cache`); extend the same pattern to any further report whose latency grows with history.
- Add zero-downtime migration and rollback procedures.

## Decision Points

- Is HowMuch meant to be self-hosted for the user, or centrally hosted for other people?
- For the first beta, is one database/deployment per user acceptable?
- Is Cloudflare Workers a hard platform requirement, or is Cloudflare only needed as the public edge?
- Is iOS/OpenClaw auth allowed to remain token-based, or should beta require account login from day one?
- What is the minimum acceptable restore point objective and restore time objective once real external users enter data?

## Practical Default

For the next milestone, keep SQLite and ship the current Bun API on a persistent host with automated encrypted backups. Add the DB adapter and tenant/auth design only when the first external-user path is real. When there is credible commercial demand, migrate deliberately to Postgres instead of stretching the current single-user SQLite architecture into shared SaaS.
