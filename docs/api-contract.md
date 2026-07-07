# API Contract

This contract is intentionally smaller than the full YNAB API. It covers the endpoints and fields used by existing local projects and OpenClaw.

## Compatibility Principles

- Keep YNAB-style response envelopes: `{ "data": ... }`.
- Store and return amounts as integer milliunits on `/v1`.
- Use ISO `YYYY-MM-DD` dates.
- Support both `/plans/{id}` and `/budgets/{id}` aliases.
- Accept `PATCH` and `PUT` on individual transactions.
- Return `server_knowledge` where practical, even if early clients do not need strict deltas.

## Authentication

Request:

```http
Authorization: Bearer <token>
```

For local development, the API may allow all requests if no token is configured. Production should set `HOWMUCH_API_TOKEN`.

Error responses follow the YNAB wrapper shape:

```json
{
  "error": {
    "id": "401",
    "name": "not_authorized",
    "detail": "Invalid bearer token"
  }
}
```

## YNAB-Compatible Endpoints

### User

`GET /v1/user`

Returns:

```json
{
  "data": {
    "user": {
      "id": "local-user"
    }
  }
}
```

### Plans/Budgets

`GET /v1/plans`

`GET /v1/budgets`

Returns `plans` for `/plans` and `budgets` for `/budgets`, with the same records.

### Settings

`GET /v1/plans/{plan_id}/settings`

Returns date format, currency format, and custom flag names.

### Accounts

`GET /v1/plans/{plan_id}/accounts`

`GET /v1/budgets/{budget_id}/accounts`

`GET /v1/plans/{plan_id}/accounts/{account_id}`

`POST /v1/plans/{plan_id}/accounts`

Create body: `{ "account": { "name": "Savings", "type": "savings", "balance": 0 } }`. The
server generates an id when none is supplied and treats `balance` as the opening
balance. Every account also owns a `Transfer : <name>` payee (created on demand
and backfilled by migration), exposed through `transfer_payee_id`.

Account fields to return:

- `id`
- `name`
- `type`
- `on_budget`
- `closed`
- `balance`
- `cleared_balance`
- `uncleared_balance`
- `transfer_payee_id`
- `direct_import_linked`
- `direct_import_in_error`
- `deleted`

### Payees

`GET /v1/plans/{plan_id}/payees`

`POST /v1/plans/{plan_id}/payees`

`GET /v1/plans/{plan_id}/payees/{payee_id}/transactions`

Create body:

```json
{
  "payee": {
    "name": "Merchant Name"
  }
}
```

### Categories

`GET /v1/plans/{plan_id}/categories`

Return category groups with categories. Assignment fields may be present for compatibility but should be zero/null when not meaningful.

### Months

`GET /v1/plans/{plan_id}/months/{month}`

The current daily summary depends on `month.categories[].activity`. The service can compute activity from transactions for the requested calendar month.

### Transactions

List:

`GET /v1/plans/{plan_id}/transactions`

Supported query parameters:

- `since_date`
- `until_date`
- `type`
- `last_knowledge_of_server`

When `last_knowledge_of_server` is provided, the transaction list returns transactions changed since that knowledge value, including deleted rows so incremental clients can tombstone local copies.

Scoped lists:

- `GET /v1/plans/{plan_id}/accounts/{account_id}/transactions`
- `GET /v1/plans/{plan_id}/payees/{payee_id}/transactions`
- `GET /v1/plans/{plan_id}/categories/{category_id}/transactions`
- `GET /v1/plans/{plan_id}/months/{month}/transactions`

Bulk import:

`POST /v1/plans/{plan_id}/transactions/import`

Request body:

```json
{
  "transactions": [
    {
      "account_id": "account-id",
      "date": "2026-06-10",
      "amount": -12340,
      "payee_name": "Merchant",
      "import_id": "source-unique-id"
    }
  ]
}
```

Response fields:

- `transaction_ids`
- `duplicate_import_ids`
- `duplicate_transaction_ids`
- `server_knowledge`

Create:

`POST /v1/plans/{plan_id}/transactions`

Minimum create body:

```json
{
  "transaction": {
    "account_id": "account-id",
    "date": "2026-06-10",
    "amount": -12340,
    "payee_id": null,
    "payee_name": "Merchant",
    "category_id": null,
    "memo": "source note",
    "flag_color": "yellow"
  }
}
```

If a single create request includes an `import_id` that already exists for the plan, the API returns the existing transaction rather than creating a duplicate. This makes retrying OpenClaw writes safe even when the caller uses the single-transaction endpoint instead of the bulk import endpoint.

Individual transaction:

- `GET /v1/plans/{plan_id}/transactions/{transaction_id}`
- `PUT /v1/plans/{plan_id}/transactions/{transaction_id}`
- `PATCH /v1/plans/{plan_id}/transactions/{transaction_id}`
- `DELETE /v1/plans/{plan_id}/transactions/{transaction_id}`

Updatable fields:

- `date`
- `amount`
- `payee_id`
- `payee_name`
- `category_id`
- `memo`
- `cleared`
- `approved`
- `flag_color`
- `flag_name`

Transfers (YNAB semantics):

- Creating a transaction whose `payee_id` is another account's
  `transfer_payee_id` (or that carries a `transfer_account_id`) creates the
  mirrored transaction in the target account. Both sides link through
  `transfer_account_id`/`transfer_transaction_id` and use `Transfer : <account>`
  payees.
- Transfers between two on-budget accounts carry no category; transfers to a
  tracking account keep the category supplied on the on-budget side.
- Updating one side keeps the other in step (date, amount negated, memo).
  Changing the payee to a regular payee deletes the mirrored side; changing it
  to a different transfer payee moves the mirrored side to the new account.
- Deleting either side deletes both.
- `cleared` and flags stay per-side.

Splits:

- Create bodies may include `subtransactions` (each with `amount`,
  `category_id`, optional `payee_id`/`payee_name`/`memo`). Amounts must sum to
  the transaction amount or the API returns `400 bad_request`.
- Split parents carry no category of their own and report `category_name`
  `"Split"`.
- A subtransaction whose payee is a transfer payee creates a mirrored
  transaction in the target account, linked through the subtransaction's
  `transfer_transaction_id`. Deleting the split deletes the mirrored sides;
  removing a split line deletes its mirrored side.
- Patching other fields preserves existing subtransactions.

Validation errors use the YNAB shape with `"name": "bad_request"` and HTTP 400.

Transaction response fields:

- `id`
- `date`
- `amount`
- `memo`
- `cleared`
- `approved`
- `flag_color`
- `flag_name`
- `account_id`
- `account_name`
- `payee_id`
- `payee_name`
- `category_id`
- `category_name`
- `transfer_account_id`
- `transfer_transaction_id`
- `matched_transaction_id`
- `import_id`
- `import_payee_name`
- `import_payee_name_original`
- `deleted`
- `subtransactions`

## Native Endpoints

### Reports

`GET /api/reports/spending-breakdown`

`GET /api/reports/income-vs-spending`

`GET /api/reports/net-worth`

`GET /api/reports/age-of-money`

Common filters:

- `from`
- `to`
- `account_ids`
- `category_ids`
- `category_group_ids`
- `payee_ids`
- `include_transfers`

By default reports count categorised transfer lines (for example a categorised
payment to a tracking account) as spending, matching YNAB; only uncategorised
transfer legs are excluded. `include_transfers=true` includes every transfer
line.

Extra filters:

- `include_closed_accounts` on Net Worth
- `top_payees_limit` on Spending Breakdown
### Mobile Quick Entry

`POST /api/mobile/quick-entry`

Body:

```json
{
  "client_id": "ios-generated-id",
  "account_id": "account-id",
  "date": "2026-06-10",
  "amount": "-12.34",
  "payee_id": null,
  "payee_name": "Merchant",
  "category_id": null,
  "memo": "optional",
  "flag_color": null,
  "subtransactions": [
    { "amount": "-8.34", "category_id": "cat-a", "memo": "optional" },
    { "amount": "-4.00", "category_id": "cat-b" }
  ]
}
```

`payee_id` may be an account's `transfer_payee_id` to record a transfer, and
`subtransactions` (optional, decimal amounts) records a split; both follow the
`/v1` transfer and split semantics above.

Returns a normal YNAB-compatible transaction envelope.

### Imports

`POST /api/import/ynab`

Starts a YNAB migration using a supplied token and plan id. The importer should fetch full history explicitly.

`POST /api/import/csv`

Accepts rows shaped like:

```json
{
  "account_id": "account-id",
  "rows": [
    {
      "date": "2026-06-10",
      "payee": "Merchant",
      "memo": "optional",
      "outflow": "12.34",
      "inflow": ""
    }
  ]
}
```
