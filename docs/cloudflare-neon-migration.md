# Cloudflare Workers + Neon Migration

This is the gated migration path from the current Bun/SQLite deployment to a
Cloudflare Worker backed by Neon Postgres. SQLite remains the source of truth
until the production cutover and reconciliation checks have passed.

## Gate 1: Freeze A Reproducible Baseline

Create a local, ignored baseline from the real ledger:

```sh
bun run baseline:sqlite --output data/migration-baseline.json
```

Re-run it before any cutover to prove the source has not changed unexpectedly:

```sh
bun run baseline:sqlite --compare data/migration-baseline.json
```

The manifest contains row counts and SHA-256 fingerprints for every ledger
table, aggregate account/transaction values, and result fingerprints for all
four report families. It contains financial totals, so it belongs under the
gitignored `data/` directory and must not be committed.

## Migration Gates

1. Capture the SQLite baseline and keep a recoverable database backup.
2. Introduce an asynchronous query/transaction interface with both SQLite and
   Neon implementations.
3. Translate the schema and repository/report SQL to Postgres and pass the API
   suite against both engines.
4. Run a dry-run copy into a disposable Neon branch. Compare table counts,
   transaction/account aggregates, and report results to the SQLite baseline.
5. Deploy the Worker and web assets to a preview environment. Verify bearer
   auth, iOS reads and offline writes, imports, transfers, splits, and reports.
6. Run the scheduled YNAB sync twice and prove that the second pass is
   idempotent and that overlapping invocations are safely serialised.
7. Stop writes briefly, back up SQLite, perform the production copy, reconcile,
   deploy, and verify the live clients.

Any failed reconciliation stops the cutover. Production rollback is the prior
Worker deployment plus the untouched SQLite database; do not allow writes to
both databases after the cutover point.
