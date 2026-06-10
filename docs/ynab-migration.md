# YNAB Migration

Preferred migration source: the YNAB API with a personal access token.

Why this path:

- Preserves plan metadata, accounts, payees, categories, flags, cleared state, imports, transfers, split transactions, and deleted transactions.
- Is repeatable without manual browser exports.
- Lets HowMuch compare imported account balances against YNAB's current account balances after the import.

Fallback sources such as a YNAB web export or a downloaded CSV are still useful for manual recovery, but they are not the parity path for a full ledger migration.

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
