# HowMuch Architecture

HowMuch is a single-hosted personal ledger with a YNAB-compatible edge. It should accept existing OpenClaw-style transaction writes with minimal changes while owning a cleaner internal schema for reports and future clients.

## Monorepo Shape

Planned layout:

- `apps/api`: Bun TypeScript API and SQLite persistence.
- `apps/web`: report-first web app.
- `apps/ios`: iOS quick-entry and report companion app.
- `docs`: research, architecture, API contract, and migration notes.

## Storage Choice

Use SQLite for the first version.

Reasons:

- Single-user and single-hosted.
- Simple backup, snapshot, and restore story.
- Good enough for all report queries at personal-finance scale.
- Easy future upgrade path to Postgres if multi-user accounts become real.

The API stores amounts as integer milliunits at the compatibility boundary and in the ledger tables. Decimal display formatting happens only at the edge.

## Core Data Model

Tables:

- `plans`: the top-level ledger container. YNAB calls this a plan now and a budget historically.
- `accounts`: account metadata and current cached balances.
- `category_groups`: report groupings.
- `categories`: transaction categories.
- `payees`: normalised merchant/payee names.
- `transactions`: ledger entries.
- `subtransactions`: split transaction lines.
- `source_events`: optional raw ingestion trace from OpenClaw, CSV import, mobile quick entry, or YNAB migration.
- `import_sessions`: import run metadata.
- `import_rows`: row-level import diagnostics.
- `sync_state`: monotonic server knowledge for YNAB-style incremental clients.

Transaction essentials:

- `id`
- `plan_id`
- `account_id`
- `date`
- `amount_milli`
- `payee_id`
- `payee_name_snapshot`
- `category_id`
- `category_name_snapshot`
- `memo`
- `cleared`
- `approved`
- `flag_color`
- `flag_name`
- `transfer_account_id`
- `transfer_transaction_id`
- `matched_transaction_id`
- `import_id`
- `import_payee_name`
- `import_payee_name_original`
- `external_ynab_id`
- `deleted`
- timestamps

The schema deliberately keeps YNAB ids separately as external ids so imported history can retain provenance while new transactions use owned ids.

## API Boundary

Expose two API families:

1. YNAB-compatible routes under `/v1/plans/{id}` and `/v1/budgets/{id}`.
2. Native routes under `/api` for reports, import jobs, and mobile quick entry.

For OpenClaw, the critical route is:

`POST /v1/plans/{id}/transactions`

It accepts:

- `account_id`
- `date`
- `amount`
- `payee_id`
- `payee_name`
- `category_id`
- `memo`
- `flag_color`
- optional `import_id`
- optional `cleared`
- optional `approved`
- optional `subtransactions`

The API also supports payee creation and payee/category/account lookups because the current scripts use YNAB as a normalisation service before creating transactions.

## Reports

Reports are computed from transactions and account metadata, not budget assignments.

### Spending Breakdown

Input filters:

- `from`
- `to`
- account ids
- category ids or category group ids
- payee ids
- include/exclude transfers

Query:

- Select negative transaction amounts.
- Exclude deleted rows.
- Exclude transfers unless explicitly included.
- If a transaction has subtransactions, group negative subtransaction amounts by their category.
- Otherwise group the transaction amount by transaction category.

Output:

- Category/category group totals in positive milliunits.
- Share of total.
- Transaction count.
- Optional top payees.

### Income vs Spending

Input filters:

- `from`
- `to`
- interval: day, week, month, year
- account ids
- category ids

Query:

- Positive non-transfer amounts are income.
- Negative non-transfer amounts are spending.
- Splits are expanded where present.

Output:

- Interval rows with income, spending, net, and cumulative net.

### Net Worth

Input filters:

- `from`
- `to`
- interval: day, week, month
- account ids
- include/exclude closed accounts

Query:

- Start from imported opening balances or the earliest transaction baseline.
- Sum transaction amounts by account through each period end.
- Exclude deleted transactions.

Output:

- Period end total.
- Account breakdown.
- Delta from previous period.

### Age Of Money

Input filters:

- `from`
- `to`
- interval: day, week, month
- account ids

Query:

- Treat positive inflows as FIFO lots.
- Match spending outflows against oldest available lots.
- Age is spending date minus income lot date, weighted by amount spent.
- Ignore credit-card float and envelope concepts by design.

Output:

- Period weighted average age in days.
- Optional median/percentile later.
- Diagnostic counts for unmatched spending before migration baseline.

## Mobile Quick Entry

Native quick entry should accept the same core transaction shape as OpenClaw, plus mobile-only idempotency:

- `client_id`
- `account_id`
- `date`
- decimal or milliunit amount
- `payee_name`
- optional `category_id`
- optional `memo`
- optional `flag_color`
- optional source metadata

The server converts decimal amounts to milliunits, creates or reuses payees, and returns the YNAB-compatible transaction shape.

## Auth

Version one is single-user:

- Static bearer token for API clients.
- Local network deployment by default.
- No accounts or multi-user identity model yet.

Later:

- Session auth for web.
- Device tokens for iOS.
- Optional OpenClaw ingestion token scoped to create/read payees, accounts, categories, and transactions.

## Migration Path

1. Connect to YNAB using a personal access token.
2. Fetch plans and pick the current plan.
3. Fetch settings, accounts, category groups/categories, payees, and all historical transactions.
4. Explicitly request full history rather than relying on YNAB's default transaction date window.
5. Preserve external YNAB ids in `external_ynab_id`.
6. Preserve `import_id`, flags, memos, cleared status, subtransactions, and transfer links.
7. Recompute account balances from imported transactions and compare with imported account balances.
8. Generate parity reports for Spending Breakdown, Income vs Spending, Net Worth, and Age of Money.
9. Point OpenClaw at HowMuch's `/v1` API base URL and run in shadow mode before cutting over writes.

