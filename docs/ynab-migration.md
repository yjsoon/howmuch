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
