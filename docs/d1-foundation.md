# Inactive Cloudflare D1 foundation

Production remains on Neon. There is deliberately no D1 binding in
`apps/worker/wrangler.jsonc`, and the Worker has not been switched.

## Schema

For a **new, explicitly named inactive** D1 database, apply the existing
SQLite migrations `apps/api/migrations/001_initial.sql` through `003`, followed
by `apps/api/d1-migrations/004_d1_hosted_foundation.sql`. The last migration
adds deterministic ledger sequences, scheduler state, audit data, and the
`write_state`/`write_commands` version guard used by the atomic write planners,
plus `migration_runs` and immutable chunk identities used by the copy tool. Do
not apply it to a live database.

`D1Database` supports ordinary async statements and explicit atomic `batch()`.
Its interactive `transaction()` always throws. `D1LedgerRepository` reuses the
existing read/formatting surface while routing every mutation through guarded,
preplanned D1 batches; transaction/split/transfer graphs are never sent through
the inherited interactive write path. `D1ReportService` uses the async D1 API.

`D1ScheduledSyncState` provides the atomic lease state machine, and
`runD1ScheduledYnabSync` injects the attempt lease into every metadata, ledger,
and import receipt command while renewing during long imports. Every terminal
transition requires current lease ownership. The Worker has a dormant backend
selector, but production defaults to Neon and no D1 binding exists yet.

## Import safety and verification

Generate the deterministic SQLite baseline before any copy:

```sh
bun run baseline:sqlite -- --db data/howmuch-real.sqlite --output data/d1-baseline.json
```

Use Wrangler only with a literal, explicitly reviewed inactive database name;
never use a binding/default and never reuse the production name:

```sh
wrangler d1 execute howmuch-INACTIVE-migration --remote --file apps/api/migrations/001_initial.sql
wrangler d1 execute howmuch-INACTIVE-migration --remote --file apps/api/migrations/002_transaction_server_knowledge.sql
wrangler d1 execute howmuch-INACTIVE-migration --remote --file apps/api/migrations/003_transfer_payees.sql
wrangler d1 execute howmuch-INACTIVE-migration --remote --file apps/api/d1-migrations/004_d1_hosted_foundation.sql
```

Generate only (the default; it never contacts Cloudflare):

```sh
bun run migrate:d1:inactive -- --sqlite data/howmuch-real.sqlite --output data/d1-import --max-rows 200 --max-bytes 750000
```

The source is opened read-only under one held read snapshot and iterated a row
at a time in foreign-key order. The run identity is a typed logical hash of the
exact snapshot, not the main SQLite file bytes (which would omit WAL-only rows).
SQL uses ordinary `INSERT` (collisions fail), explicit rowid-derived
ledger sequences, and size-bounded Wrangler `--file` batches containing both
rows and their checkpoint. D1 rejects SQL `BEGIN`/`COMMIT`; Wrangler sends the
statements in one file atomically (also covered by the local D1 integration
check). The manifest records source SHA-256, table/chunk, count, canonical hash,
and first/last stable keys. Resume reads receipts from D1 itself; an external
manifest is deliberately not trusted to skip remote work. Any run identity or
checkpoint disagreement stops the import, and a run is marked complete only
after every expected checkpoint exists.

Execution is intentionally cumbersome: supply `--execute`, both
`--database-name` and `--database-id`, and the exact typed value
`--confirm-inactive 'INACTIVE <name> <id>'`. The name must visibly contain
`INACTIVE`; the tool checks Wrangler's database identity and runs files
sequentially. Authentication is accepted only through Wrangler's environment
or login, never CLI options, and is not printed. This process remains authorized
only for a reviewed inactive target.

Reconciliation is read-only. Export the inactive D1 database, then compare the
export directly with the source. The verifier loads the SQL export into a
temporary local SQLite database and deletes it afterward:

```sh
wrangler d1 export howmuch-INACTIVE-migration --remote --output data/howmuch-INACTIVE-export.sql
bun run verify:d1:inactive -- --sqlite data/howmuch-real.sqlite --destination-sql data/howmuch-INACTIVE-export.sql
```

It compares common-column table counts/canonical hashes, totals by plan/account,
cached versus derived balances, split sums, reciprocal transfers, orphans,
server-knowledge bounds, sequence uniqueness/contiguity, and all four report
families over each plan's explicit ledger date range. A mismatch exits nonzero.
These are reconciliation results only; do not fabricate or record results for a
ledger that was not actually checked. No production copy, Worker binding change,
or deployment is authorized by this tooling.

## Dormant Worker selection and rollback

The Worker selects Neon unless `HOWMUCH_DATABASE_BACKEND=d1` is explicitly set.
Selecting D1 without a `DB` binding fails closed. The binding cannot be checked
in until the inactive database has been created and its real UUID reviewed; do
not use a placeholder UUID. A later, separately approved preview step is:

1. Create and migrate a clearly named inactive D1 database.
2. Import and reconcile it with the commands above.
3. Add its exact UUID as the preview environment's `DB` binding only.
4. Set `HOWMUCH_DATABASE_BACKEND=d1` only in preview and deploy preview.
5. Verify bearer auth, reports, reversible transaction graphs, duplicate cron
   delivery, lease takeover, and a YNAB delta.

Production remains a separate gate. Rollback is the previous Worker deployment
with the selector absent/`neon`, using the retained and unmodified Neon database.
Do not retire Neon until D1 has passed the separately approved live observation
window.
