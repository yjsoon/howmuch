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

Scoped lists:

- `GET /v1/plans/{plan_id}/accounts/{account_id}/transactions`
- `GET /v1/plans/{plan_id}/payees/{payee_id}/transactions`
- `GET /v1/plans/{plan_id}/categories/{category_id}/transactions`
- `GET /v1/plans/{plan_id}/months/{month}/transactions`

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

### Mobile Quick Entry

`POST /api/mobile/quick-entry`

Body:

```json
{
  "client_id": "ios-generated-id",
  "account_id": "account-id",
  "date": "2026-06-10",
  "amount": "-12.34",
  "payee_name": "Merchant",
  "category_id": null,
  "memo": "optional",
  "flag_color": null
}
```

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

