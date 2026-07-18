# Integration Status

Last updated: 2026-07-18

## Current State

| Track | Status | Notes |
| --- | --- | --- |
| Local backend | Ready | Bun + SQLite remains supported; the full 42-test suite passes. |
| Hosted backend | Preview-ready | Shared async API handlers run against Postgres; Worker typecheck and dry-run bundle pass. |
| Ledger migration | Verified locally | The real 52,788-transaction ledger copies exactly, including table fingerprints and all four report fingerprints. |
| Web | Ready | Production Vite build passes; deployed auth is entered through an unlock screen and retained only for the browser tab. |
| iOS | Ready for live connection | App build passes; bearer token is stored in Keychain and connection settings support the deployed Worker URL. |
| YNAB sync | Ready | Production scheduled handler uses delta cursors, retry deduplication, a database lease, and failure recovery. |
| Cloud infrastructure | Awaiting ownership choice | Cloudflare account is authenticated. Neon is authenticated, but the only visible free organisation may be work/shared and must be confirmed before creating the personal project. |

## Verified

- SQLite baseline captured from the real `Actual Budget` plan: 112 accounts and
  52,788 transactions.
- Postgres migration preserves exact row counts and hashes across plans,
  accounts, categories, payees, transactions, source events, import sessions,
  and import rows.
- Spending breakdown, income versus spending, net worth, and age-of-money report
  fingerprints match SQLite exactly.
- Postgres API smoke covers bearer auth, ordinary and split transfers, import
  idempotency, CSV ingestion, offline client IDs, reports, balances, and
  incremental deletion.
- Scheduled-sync smoke covers initial full import, incremental cursor advance,
  duplicate scheduled delivery, overlapping lease rejection, and lease release
  after a failed import.
- React production build, iOS simulator build, Worker typecheck, and Wrangler
  deployment dry run pass.

## Remaining Deployment Gates

- [ ] Confirm the Neon organisation that should own this personal project.
- [ ] Create Singapore Neon project plus isolated preview branch.
- [ ] Migrate and reconcile the real ledger on preview Neon.
- [ ] Store independent preview secrets and deploy `howmuch-preview`.
- [ ] Verify the live preview web, API, reports, transfers/imports, and iOS read/write path.
- [ ] Re-capture/freeze SQLite, make and open a recoverable backup, then migrate production.
- [ ] Store production secrets and deploy `howmuch` with the hourly cron.
- [ ] Verify production clients, a reversible live write, first scheduled delta sync, logs, and rollback artefacts.

The detailed gates and commands are in [the deployment runbook](deployment.md).
