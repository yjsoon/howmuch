# YNAB Usage Audit

Date: 2026-06-10

This audit covers YNAB-related code found under:

- `/Users/yingjie/Developer/tt-projects`
- `/Users/yingjie/Developer/personal-projects`
- `/Users/yingjie/Developer/work`
- `mbpro:~/.openclaw`

The current replacement should optimise for the YNAB surface that is actually used: transaction ingestion, transaction reports, account balances, payee/category lookup, and a few update flows. It should not model envelope budgeting, target assignment, or YNAB credit-card mechanics as first-class product concepts.

## Public YNAB API Notes

Current YNAB docs describe a REST JSON API at `https://api.ynab.com/v1`, authenticated with bearer tokens. Amounts are integer milliunits where `1000` equals one currency unit, and dates are ISO `YYYY-MM-DD`.

The current docs use `/plans/{plan_id}`. The changelog says the old `/budgets/{budget_id}` paths remain supported even though they are no longer the documented path. Local code still uses both, so this service should expose both aliases.

The transaction list endpoint now defaults `since_date` to one year ago when omitted, so any historical importer must explicitly request the full range.

Sources checked:

- https://api.ynab.com/
- https://api.ynab.com/v1
- https://api.ynab.com/papi/open_api_spec.yaml

## Local Projects

### `personal-projects/ynab-rewards-tracker`

Purpose: reward optimisation and transaction review across web and mobile clients.

API surface:

- `GET /v1/plans`
- `GET /v1/plans/{plan_id}/settings`
- `GET /v1/plans/{plan_id}/accounts`
- `GET /v1/plans/{plan_id}/categories`
- `GET /v1/plans/{plan_id}/payees`
- `GET /v1/plans/{plan_id}/transactions`
- `PATCH /v1/plans/{plan_id}/transactions/{transaction_id}` for flag updates
- Generic web proxy forwards `GET`, `POST`, and `PATCH`

Fields used:

- Plans: `id`, `name`, `last_modified_on`, `first_month`, `last_month`, `date_format`, `currency_format`
- Accounts: `id`, `name`, `type`, `on_budget`, `closed`, `balance`, `cleared_balance`, `uncleared_balance`, `transfer_payee_id`, `direct_import_linked`, `direct_import_in_error`, `deleted`
- Payees: `id`, `name`, `transfer_account_id`, `deleted`
- Categories: group and category `id`, `name`, `hidden`, `deleted`; category ids are mostly for display/filtering
- Transactions: `id`, `date`, `amount`, `account_id`, `account_name`, `payee_id`, `payee_name`, `category_id`, `category_name`, `memo`, `cleared`, `approved`, `flag_color`, `flag_name`, `import_id`, `import_payee_name`, `import_payee_name_original`, `deleted`, `subtransactions`
- Settings: `settings.display.flag_names`, used to map custom flag names

Shape out:

- Uses milliunit amounts internally for fetched YNAB transactions.
- Reward advice and UI summaries convert to decimal currency for display.
- Main grouping axis is account/card, date range, flag colour/name, payee, category, and memo.

Model dependency verdict:

- Uses transactions, accounts, payees, categories, flags, settings.
- Does not use assigned/available envelope values, goals, targets, scheduled transactions, loans, direct import metadata beyond display fields, or YNAB credit-card payment behaviour.

### `work/tools/claim-manager`

Purpose: find YNAB transactions marked as receipt TODOs and link/claim receipts.

API surface:

- `GET /v1/budgets/{budget_id}/transactions?since_date=...`
- `GET /v1/budgets/{budget_id}/transactions/{transaction_id}`
- `PUT /v1/budgets/{budget_id}/transactions/{transaction_id}` with a new memo

Fields used:

- `id`
- `date`
- `amount`
- `account_name`
- `payee_name`
- `memo`
- `category_name`
- `transfer_transaction_id`
- `subtransactions`

Shape in:

- Reads YNAB transaction and subtransaction arrays.
- Looks for memos matching `TODO`.
- Skips the positive side of transfers.
- Converts `abs(amount) / 1000` for receipt claim amounts.

Shape out:

- `YnabTodo`: `id`, `date`, `payee`, decimal `amount`, `description`, `accountName`, optional `categoryName`, `source`, optional `parentTransactionId`.
- Memo update changes `TODO` to `CLAIMED`.

Model dependency verdict:

- Uses memo, category, transfer link, and subtransaction detail.
- Does not use budget month assignment, goals, approvals, cleared state, flags, or credit-card features.

### `personal-projects/ynab-formatter`

Purpose: OCR/vision extraction of credit card statement images into a YNAB CSV-style import table.

API surface:

- No YNAB API calls.

Fields produced:

- `date` as `YYYY-MM-DD`
- `payee`
- `memo`
- `outflow`
- `inflow`

Shape out:

- CSV-compatible rows equivalent to YNAB import columns: `Date`, `Payee`, `Memo`, `Outflow`, `Inflow`.
- Amounts are decimal strings, not milliunits.

Model dependency verdict:

- This is importer input, not live API compatibility.
- The new service should accept this shape for manual/import fallback.

### `personal-projects/expense-tracker`

Purpose: older product/spec exploration for a YNAB-inspired tracker.

API surface:

- No YNAB API calls.

Useful model ideas:

- Accounts, currencies, categories, transactions, tags, and import sessions.
- Transaction fields: `account_id`, `category_id`, `amount`, `currency_id`, `exchange_rate`, `home_amount`, `payee`, `memo`, `date`, `is_cleared`.
- Report ideas overlap the current goal: Spending Breakdown, Spending Trends, Net Worth, Income vs Expense, and Age of Money.

Model dependency verdict:

- Confirms the replacement should be transaction/report-led rather than envelope-led.

### `tt-projects`

No active YNAB integration was found. Matches were package-lock noise or unrelated `category_id` style fields.

## OpenClaw On `mbpro`

Active jobs are shell scripts under `~/.openclaw/workspace/scripts`, with an older PDF reconciliation script under `~/.openclaw/scripts`.

### Common Read/Write Pattern

Most monitors do this:

1. Read recent Gmail or iMessage alerts.
2. Extract merchant, card/account, date, amount, and sometimes original currency.
3. Convert outflows to negative YNAB milliunits.
4. Fetch payees and fuzzy-match merchant names.
5. Create a payee when no match exists.
6. Fetch the payee's latest transaction to reuse `category_id`.
7. Check for duplicates by account/date/amount/payee-ish text.
8. Create a transaction.

Common transaction-create payload:

```json
{
  "transaction": {
    "account_id": "account-id",
    "date": "YYYY-MM-DD",
    "amount": -12340,
    "payee_id": "existing-payee-id-or-null",
    "payee_name": "merchant when no payee id",
    "category_id": "category-id-or-null",
    "memo": "optional memo",
    "flag_color": "optional flag colour"
  }
}
```

The payload is already close to an owned ledger schema. It is an account ledger entry with optional normalised payee/category references, a source memo, and an optional review flag.

### Script-Specific Inputs

`uob-6718-gmail-monitor.sh`

- Source: Gmail from `unialerts@uobgroup.com`.
- Extracts card 6718 transactions from email snippets: currency, original amount, `DD/MM/YY` date, merchant.
- Non-SGD amounts are estimated to SGD and memoed for later correction.
- Writes `account_id`, `date`, `amount`, `payee_id` or `payee_name`, `category_id`, `memo`, `flag_color`.

`uob-monitor.sh`

- Source: iMessage chat 1343.
- Extracts UOB card alerts and some PayNow-style transfers.
- Card ending maps to YNAB account.
- Writes the common payload, with `memo` always present as a string.

`dbs-monitor.sh`

- Source: iMessage chat 1279.
- Extracts DBS/POSB card alerts with amount, card ending, merchant, and date.
- Skips tiny transit authorisations and some likely pre-charges.
- Writes `account_id`, `date`, `amount`, `payee_id` or `payee_name`, `category_id`, `memo`.

`citi-monitor.sh`

- Source: Citibank iMessages.
- Extracts card ending, date, amount, merchant.
- Writes `account_id`, `date`, `amount`, `payee_id` or `payee_name`, `category_id`.

`dcs-monitor.sh`

- Source: DCSCards iMessages.
- Extracts card notification data.
- Writes `account_id`, `date`, `amount`, `payee_id` or `payee_name`, `category_id`, `memo`, `flag_color`.

`maybank-monitor.sh`

- Source: iMessage chat 1311.
- Extracts `Your Maybank Card ending XXXX was used at MERCHANT on DD/MM/YY for SGD/USDXX.XX`.
- Card ending maps to account.
- USD is estimated to SGD and memoed.
- Writes `account_id`, `date`, `amount`, `payee_id` or `payee_name`, `category_id`, `flag_color`.

`paylah-monitor.sh`

- Source: Gmail from `paylah.alert@dbs.com`.
- Parses HTML rows for transaction type, date/time, amount, and recipient.
- Uses a fixed POSB Savings account.
- Writes `account_id`, `date`, `amount`, `payee_id` or `payee_name`, `category_id`, `memo`.

`trust-monitor.sh`

- Source: Gmail from Trust Bank.
- Parses MIME email subject/body for amount, currency, merchant, email date, and reversals/cancellations.
- Non-SGD amounts are estimated to SGD with memo text noting the source currency/rate.
- Writes `account_id`, `date`, `amount`, `payee_id` or `payee_name`, `category_id`, `memo`.

`fairprice-monitor.sh`

- Source: FairPrice Group receipt/payment emails.
- Parses HTML for paid amount, card ending, store image URL, and receipt text.
- Infers account from card ending.
- Classifies merchant as `FairPrice` or `Kopitiam`, sets category and optional yellow flag.
- Writes `account_id`, `date`, `amount`, `payee_id` or `payee_name`, `category_id`, `memo`, `flag_color`.

`amaze-monitor.sh`

- Source: Instarem Amaze Gmail emails.
- Parses MIME email for transaction amount/currency, SGD amount paid, merchant, payment source last four, and date.
- Maps source card last four to account.
- Writes `account_id`, `date`, `amount`, `payee_id` or `payee_name`, `category_id`, `memo`, `flag_color`.

`ynab-daily-summary.sh`

- Read-only summary.
- Reads `GET /plans/{id}/months/{YYYY-MM-01}` for category activity.
- Reads `GET /plans/{id}/transactions?since_date=today`.
- Uses negative category activity and negative categorised transaction/subtransaction amounts.

`pdf-ynab-reconcile.sh`

- Source: local PDF statement text extracted with `pdftotext`.
- Reads account transactions with `since_date` and `until_date`.
- Optionally clears matched transactions by updating `cleared` to `cleared`.

### Screenshots/OCR

No active OpenClaw screenshot or OCR path was found for writing to YNAB. There are email HTML parsers, iMessage parsers, and a PDF text reconciliation script. The local `ynab-formatter` project handles image-to-CSV extraction, but it does not call the YNAB API directly.

## Union Of Actual API Surface

Compatibility endpoints that matter:

- `GET /v1/user`
- `GET /v1/plans`
- `GET /v1/budgets` as a legacy alias
- `GET /v1/plans/{id}/settings`
- `GET /v1/plans/{id}/accounts`
- `GET /v1/plans/{id}/accounts/{account_id}/transactions`
- `GET /v1/plans/{id}/categories`
- `GET /v1/plans/{id}/payees`
- `POST /v1/plans/{id}/payees`
- `GET /v1/plans/{id}/payees/{payee_id}/transactions`
- `GET /v1/plans/{id}/months/{month}`
- `GET /v1/plans/{id}/transactions`
- `POST /v1/plans/{id}/transactions`
- `GET /v1/plans/{id}/transactions/{transaction_id}`
- `PUT /v1/plans/{id}/transactions/{transaction_id}`
- `PATCH /v1/plans/{id}/transactions/{transaction_id}`
- The same practical routes under `/v1/budgets/{id}/...`

Useful but not currently core:

- `POST /v1/plans/{id}/transactions/import`, for YNAB importer parity.
- Category/payee/account scoped transaction reads for future UI filtering.

Query parameters used:

- `since_date`
- `until_date`
- `type`
- `last_knowledge_of_server`

## Used YNAB Model

Genuinely used:

- Plans/budgets as a single ledger container.
- Accounts and balances.
- Transactions and subtransactions.
- Payees.
- Categories and category groups for reporting/filtering.
- Memos as workflow state (`TODO`, `CLAIMED`, source notes).
- Flags and custom flag names.
- Cleared status for PDF reconciliation.
- Transfer transaction ids to avoid double-counting.
- Import ids and import payee fields as imported-history metadata.
- Server knowledge for incremental sync where available.
- Month category activity for daily summary/report parity.

Mostly ignored:

- Envelope assignment values: assigned, available, budgeted.
- Targets/goals and goal cadence.
- YNAB credit-card payment handling.
- Scheduled transactions.
- Loans.
- Direct import connection state except incidental display fields.
- Multi-user sharing.
- Reconciliation state beyond `cleared`.
- Payee locations.

