# HowMuch Deployment Runbook

The production shape is one Cloudflare Worker serving the built React app and
the `/api`, `/v1`, and `/health` routes from the same origin. Ledger data lives
in Neon Postgres. Local development continues to use Bun and SQLite.

## Environments

| Environment | Worker | Neon branch | Scheduled YNAB sync |
| --- | --- | --- | --- |
| Preview | `howmuch-preview` | `preview` | Disabled |
| Production | [`howmuch.soon.sg`](https://howmuch.soon.sg) | Default protected branch | Hourly |

Use Neon's Singapore region (`aws-ap-southeast-1`). Keep preview and production
in the same project so the preview branch can be recreated without copying data
through another provider.

## Secrets

Never put these values in Git, Wrangler configuration, logs, or shell history:

- `DATABASE_URL`: pooled Neon connection string for the matching branch.
- `HOWMUCH_API_TOKEN`: independent random bearer token for each environment.
- `HOWMUCH_YNAB_TOKEN`: production-only YNAB personal access token.

Set them through Wrangler's encrypted secret store:

```sh
cd apps/worker
wrangler secret put DATABASE_URL --env preview
wrangler secret put HOWMUCH_API_TOKEN --env preview

wrangler secret put DATABASE_URL
wrangler secret put HOWMUCH_API_TOKEN
wrangler secret put HOWMUCH_YNAB_TOKEN
```

The non-secret plan identifiers and similarity threshold live in
`apps/worker/wrangler.jsonc`. The web app keeps its bearer token in the current
browser tab only. The iOS app stores it in Keychain.

## Preview Deployment

Create a Neon `preview` branch, obtain its pooled connection string, then run:

```sh
DATABASE_URL='<preview URL>' bun run api:migrate:postgres
DATABASE_URL='<preview URL>' bun run migrate:neon -- \
  --sqlite data/howmuch-real.sqlite \
  --output data/neon-preview-verification.json
DATABASE_URL='<preview URL>' bun run verify:postgres-reports -- \
  --baseline data/migration-baseline.json
DATABASE_URL='<preview URL>' bun run verify:postgres-api
DATABASE_URL='<preview URL>' bun run verify:scheduled-sync

cd apps/web && bun run build && cd ../worker
bun run typecheck
bun run deploy:preview
```

The migration refuses a non-empty target unless `--resume` is supplied. It
copies in transactions, preserves ledger order, and verifies exact counts and
row fingerprints. Keep the generated verification file under ignored `data/`.

Verify the deployed preview before promoting it:

1. An unauthenticated `/health` request returns `401`.
2. Authenticated `/health`, `/v1/user`, accounts, transactions, and all four
   reports return successfully.
3. The web unlock screen accepts the preview token and renders the real ledger.
4. iOS connects with the preview URL and token; a test entry can be created,
   read back, and deleted.
5. Imports are idempotent and transfer/split-transfer writes retain both sides.
6. The scheduled-sync verifier proves delta cursors, retry deduplication,
   overlap leasing, and lease release after failure. Preview itself has no cron.

Run the live edge verifier with the preview Worker URL and matching secrets:

```sh
HOWMUCH_BASE_URL='<preview Worker URL>' \
HOWMUCH_DEFAULT_PLAN_ID='80bc6db0-d926-4635-a37a-1ba0787c4c4e' \
DATABASE_URL='<preview URL>' \
HOWMUCH_API_TOKEN='<preview token>' \
bun run verify:worker
```

It checks static delivery, authentication, real report reads, transfers, splits,
idempotent imports, CSV, offline entry, balances, and incremental deletion
through the deployed HTTP edge. It uses a uniquely named synthetic plan and
deletes that plan plus its import session directly from Postgres in `finally`,
so a successful or failed verification does not contaminate the real ledger.

## Production Cutover

SQLite remains the source of truth until this sequence finishes:

1. Stop all writers and rerun `bun run baseline:sqlite --compare
   data/migration-baseline.json`.
2. Copy the SQLite database and its baseline manifest to encrypted backup
   storage. Confirm both copies can be opened before continuing.
3. Run the Postgres migration against an empty production branch.
4. Run the ledger copy, report parity, and API verification commands against
   production exactly as for preview.
5. Set the production Worker secrets, build the web app, and run `bun run
   deploy` from `apps/worker`.
6. Verify authenticated reads and a reversible write through the live Worker.
7. Configure the iOS app with the production URL, token, and plan ID.
8. Trigger or wait for one production YNAB cron run. Check `sync_runs`,
   `ynab_sync_state`, and Worker logs before declaring cutover complete.

Do not resume the old writer after the production copy. Running SQLite and
Postgres as independent writable ledgers creates an unreconcilable split brain.

## Rollback And Recovery

Before the first production write, rollback is simply the previous Worker
deployment plus the untouched SQLite source. After production writes begin,
restore Neon to a new branch at a known point in time, verify it, and update the
Worker's `DATABASE_URL`; do not overwrite the damaged branch in place.

Retain:

- the last pre-cutover SQLite database and baseline manifest;
- the migration verification manifest;
- Neon point-in-time history for the account's available retention window;
- Cloudflare Worker deployment history and structured scheduled-sync logs.

Test a restore quarterly by creating a temporary Neon branch, running report
parity and API verification, then deleting the temporary branch.
