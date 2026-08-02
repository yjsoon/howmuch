# YNAB Migration

Preferred migration source: the YNAB API with a personal access token.

Why this path:

- Preserves plan metadata, accounts, payees, categories, flags, cleared state, imports, transfers, split transactions, and deleted transactions.
- Is repeatable without manual browser exports.
- Lets HowMuch compare imported account balances against YNAB's current account balances after the import.

Fallback source: the official YNAB web export. This is useful when the user is already logged into the YNAB web app but cannot create or share a personal access token. It is repeatable and non-invasive, but it is not the parity path for a full ledger migration because the export does not include YNAB object IDs, deleted transactions, transfer links, split transaction structure, or API account balances.

## Safe Local Workflow

1. Set a token in the current shell without echoing it:

```sh
read -s 'YNAB_TOKEN?YNAB token: '
export YNAB_TOKEN
```

2. List the plans available to that token:

```sh
bun run import:ynab --list-plans
```

3. Import the chosen plan into a dedicated local database:

```sh
bun run import:ynab --plan-id <ynab-plan-id> --db data/howmuch-real.sqlite
```

The importer:

- Fetches the full history by default with `since_date=1900-01-01`.
- Creates `data/backups/...` automatically before overwriting an existing SQLite file, unless `--no-backup` is passed.
- Prints imported account, payee, category, transaction, and deleted-transaction counts.
- Prints an account balance mismatch count so you can spot parity issues quickly.

## Validation

Run the existing backend checks after the import:

```sh
bun test
bun run smoke
```

If you want to keep the imported ledger separate from demo data, continue using `--db data/howmuch-real.sqlite` and set `HOWMUCH_DB_PATH=data/howmuch-real.sqlite` when starting the API.

## Official Web Export Fallback

Use this path when a logged-in browser session is available but API token generation is blocked.

1. In the YNAB web app, click the plan name at the top of the left sidebar.
2. Choose **Export Plan**.
3. Confirm **Export** in the modal.
4. Import the downloaded zip into a dedicated local database:

```sh
bun run import:ynab-export -- --zip "/path/to/YNAB Export - Actual Budget as of 2026-06-11 00-25.zip" --plan-id 80bc6db0-d926-4635-a37a-1ba0787c4c4e --plan-name "Actual Budget" --db data/howmuch-real.sqlite --date-format dmy
```

The command reads the `Register.csv` and `Plan.csv` files from the zip, creates a backup before overwriting an existing SQLite file, infers blank-category transfer pairs from equal/opposite transactions within three days, marks YNAB `Transfer : ...` payee rows as transfers, and prints account, payee, category, transaction, duplicate, failed-row, and inferred-transfer counts.

Do not commit the downloaded YNAB export zip, extracted CSV/TSV files, or imported SQLite databases.

## Cloudflare D1 full-history bootstrap

Do **not** use the Worker/Cron `/api/import/ynab` route for the initial full history. Generate server-side bulk SQL offline from a dedicated, fresh API import database:

```sh
bun run bootstrap:ynab-d1 --db data/howmuch-real.sqlite --out data/ynab-d1-bootstrap.sql
```

The generator rejects ambiguous or contaminated databases (anything other than one pristine, completed YNAB API session and one plan), validates source provenance and the complete generated D1 ledger, and writes an SQL file plus a content-minimized manifest/SHA-256 with no names, payees, memos, or raw payloads. The SQL's first statement aborts unless every application, import, sync, audit, auth, and guard table is empty and `write_state` is exactly its migration default. It contains no transaction wrapper because `wrangler d1 execute --file` handles the atomic server-side upload/execution.

Keep the target quiescent for the entire bootstrap: do not configure the YNAB secret, complete first-owner setup, or allow any other writes until the import and verification finish. The emptiness check runs before the data statements, not as a lock against concurrent Worker traffic. If remote execution fails partway through, reset or recreate the target from the canonical migrations before retrying; never rerun the same file against a partially populated database.

Cloudflare **Workers Paid is a bootstrap prerequisite**. The current Free allowance is 100,000 row writes/day; canonical indexes make roughly 52,000 transactions exceed that allowance. Log in through a browser, then deploy to preview first:

```sh
bunx wrangler login
cd apps/worker
bunx wrangler d1 migrations apply DB --remote --env preview
bunx wrangler d1 execute DB --remote --env preview --file ../../data/ynab-d1-bootstrap.sql
```

If there is any doubt about the database binding or whether it is empty, stop: the emptiness guard intentionally fails rather than merge. Verify remotely without selecting names or memos:

```sh
bunx wrangler d1 execute DB --remote --env preview --command "SELECT count(*) transactions, sum(deleted=0) active, sum(deleted=1) deleted FROM transactions"
bunx wrangler d1 execute DB --remote --env preview --command "PRAGMA foreign_key_check"
bunx wrangler d1 execute DB --remote --env preview --command "SELECT plan_id,server_knowledge,lease_id,lease_until FROM ynab_sync_state"
bunx wrangler d1 execute DB --remote --env preview --command "SELECT singleton,write_version,last_command_id FROM write_state"
```

Compare counts/cursor with the manifest. Production execution and Worker deployment remain approval-gated remote operations; this generator never logs in, deploys, or contacts Cloudflare.
