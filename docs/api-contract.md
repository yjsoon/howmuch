# API Contract

This contract is intentionally smaller than the full YNAB write API. It covers the endpoints and fields used by existing local projects and OpenClaw, while retaining a lossless, read-only source mirror of imported YNAB objects. HowMuch-owned overlays provide safe mutations without rewriting that source.

## Compatibility Principles

- Keep YNAB-style response envelopes: `{ "data": ... }`.
- Store and return amounts as integer milliunits on `/v1`.
- Use ISO `YYYY-MM-DD` dates.
- Support both `/plans/{id}` and `/budgets/{id}` aliases.
- Accept `PATCH` and `PUT` on individual transactions, and `PATCH` on the transaction collection for up to 100 rows.
- Return `server_knowledge` where practical, even if early clients do not need strict deltas.

## Authentication

Browser clients authenticate with `POST /api/auth/login` and receive an `HttpOnly`, `Secure`, same-origin session cookie. Native clients exchange the same username/password credentials at `POST /api/auth/token`, then send the returned opaque session as:

```http
Authorization: Bearer <token>
```

The first owner is created once with `POST /api/auth/setup`, authorized by `HOWMUCH_API_TOKEN`. That static token remains valid for integrations, but only against `HOWMUCH_DEFAULT_PLAN_ID`. Session users can access only plans where they hold an owner, editor, or viewer membership; viewers cannot mutate data.

Error responses follow the YNAB wrapper shape:

```json
{
  "error": {
    "id": "401",
    "name": "not_authorized",
    "detail": "Invalid credentials"
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

`POST /v1/plans/{plan_id}/accounts/{account_id}/reconcile`

Create body: `{ "account": { "name": "Savings", "type": "savings", "balance": 0 } }`. The
server generates an id when none is supplied and treats `balance` as the opening
balance. Every account also owns a `Transfer : <name>` payee (created on demand
and backfilled by migration), exposed through `transfer_payee_id`.

Preview reconciliation for a statement date with:

```http
GET /v1/plans/{plan_id}/accounts/{account_id}/reconciliation?statement_date=2026-08-31
```

This read-only route is available to owners, editors, and viewers. Response data contains `account`, `statement_date`, `current_reconciled_balance`, `projected_reconciled_balance`, ordered `candidate_transaction_ids`, `candidate_transaction_count`, and `server_knowledge`. The projection starts with the opening balance and all existing non-deleted reconciled transactions, then adds non-deleted `cleared` transactions in that account dated on or before the statement date.

Commit that preview with:

```http
POST /v1/plans/{plan_id}/accounts/{account_id}/reconcile
Idempotency-Key: <stable-client-key>
Content-Type: application/json

{ "statement_date": "2026-08-31", "statement_balance": 245670 }
```

The caller must be an owner or editor; the default-plan API token is also accepted. `statement_balance` is an integer milliunit amount. The write proceeds only when the live projected balance exactly equals the statement balance. It changes precisely the preview's eligible `cleared` rows to `reconciled`; it never changes uncleared, deleted, future-dated, other-account, or other-plan rows.

Response data contains `account`, ordered `reconciled_transaction_ids`, `reconciled_transaction_count`, `statement_date`, `statement_balance`, `prior_reconciled_balance`, `final_reconciled_balance`, `replayed`, and `server_knowledge`. An exact idempotent retry replays its receipt without changing knowledge or adding another audit event. Reusing the key for another request returns `409 conflict`.

A statement mismatch returns `409 reconciliation_mismatch` with `current_reconciled_balance`, `projected_reconciled_balance`, `statement_balance`, and `difference` (`statement_balance - projected_reconciled_balance`). SQLite performs calculation and mutation in one immediate transaction. D1 verifies the exact preview snapshot inside the guarded write batch, so a concurrent clearing change returns `409 conflict` without a partial reconciliation.

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

Reconciliation requires an `Idempotency-Key` and an unwrapped body containing
integer milliunits: `{ "statement_date": "2026-08-31", "statement_balance": 123450 }`.
It reconciles only non-deleted `cleared` transactions dated on or before the
statement date, and only when their projected reconciled balance exactly matches
the supplied statement balance. A mismatch returns `409 reconciliation_mismatch`
with the current, projected, statement, and difference values; no rows change.
Successful retries return the original receipt. Reconciliation is a cutover-only
HowMuch write: it does not alter the immutable YNAB raw mirror and a later YNAB
re-import must not be used to overwrite local ledger state.

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

Return category groups with categories. For a locally created plan, assignment fields may be zero/null when not meaningful.

### Months

`GET /v1/plans/{plan_id}/months/{month}`

For an API-imported YNAB plan, this returns the imported month and category records, including assigned/budgeted, activity, balance, notes, targets, goals, and deleted flags. For a local-only plan with no imported month mirror, the service falls back to transaction-derived activity and zero/null assignment fields.

`PATCH /v1/plans/{plan_id}/months/{month}/categories/{category_id}`

Update one imported category assignment with a safe-integer milliunit value:

```json
{ "category": { "budgeted": 125000 } }
```

The value is stored as a HowMuch assignment overlay; imported YNAB objects remain unchanged. The response includes the updated `category` and projected `month`. Ready to assign and Available are recalculated from the assignment delta and current normalised month activity. Setting the amount back to the imported assignment clears the overlay.

Update a HowMuch-local target with a supported YNAB goal type and a positive integer milliunit amount:

```http
PATCH /v1/plans/{plan_id}/months/{month}/categories/{category_id}
{ "category": { "target": { "goal_type": "TB", "goal_target": 500000, "goal_target_month": "2026-12" } } }
```

`goal_type` is one of `TB`, `TBD`, `MF`, `NEED`, or `DEBT`; the target month is optional. `{ "target": null }` hides the target in a HowMuch-local overlay. `{ "restore_target": true }` deletes that overlay and returns to the exact imported target. Both target mutations are authenticated and use D1's versioned guarded-command protocol; neither mutates `ynab_raw_objects` or writes back to YNAB.

### Scheduled transactions

`GET /v1/plans/{plan_id}/scheduled_transactions`

`GET /v1/plans/{plan_id}/scheduled_transactions/{scheduled_transaction_id}`

`GET /v1/plans/{plan_id}/scheduled_subtransactions`

The collection is an effective view: untouched imported schedules are returned exactly from the YNAB mirror with their subtransactions, while HowMuch-local schedules and overlays replace source objects with the same ID. A tombstoned overlay hides its imported schedule. The source rows in `ynab_raw_objects` are never updated or deleted.

Create, replace, update, or delete an effective schedule with:

- `POST /v1/plans/{plan_id}/scheduled_transactions`
- `PATCH /v1/plans/{plan_id}/scheduled_transactions/{scheduled_transaction_id}`
- `PUT /v1/plans/{plan_id}/scheduled_transactions/{scheduled_transaction_id}`
- `DELETE /v1/plans/{plan_id}/scheduled_transactions/{scheduled_transaction_id}`

The write envelope is `{ "scheduled_transaction": { ... } }`. Create requires `account_id`, `date_first`, `frequency`, and an integer-milliunit `amount`; `date_next` defaults to `date_first`. Writable fields are `account_id`, `date_first`, `date_next`, `frequency`, `amount`, `payee_id`, `category_id`, `transfer_account_id`, `memo`, `flag_color`, and `subtransactions`. IDs are immutable. References must belong to the same plan and not be deleted. `date_next` cannot precede `date_first`.

Supported frequencies are `never`, `daily`, `weekly`, `everyOtherWeek`, `twiceAMonth`, `every4Weeks`, `monthly`, `everyOtherMonth`, `every3Months`, `every4Months`, `twiceAYear`, `yearly`, and `everyOtherYear`.

Supplying `subtransactions` replaces the complete split. It must be empty or contain at least two lines, line amounts must sum to the parent amount, and a split parent cannot have a `category_id`. Payee, category, and transfer-account references on split lines receive the same ownership validation as the parent.

Clients should send an `Idempotency-Key` on every schedule mutation. It must contain 8–128 ASCII letters, digits, dots, underscores, colons, or hyphens. An exact retry replays the original result without another version or audit event; reuse for a different request returns `409 conflict`. Create returns `201`; update and delete return `200`. Every response includes the effective `scheduled_transaction`, its `subtransactions`, and `server_knowledge`. Delete returns a tombstone with `deleted: true`.

Enter one occurrence immediately with `POST /v1/plans/{plan_id}/scheduled_transactions/{scheduled_transaction_id}/materialize`. The request requires an `Idempotency-Key` and body `{ "occurrence_date": "2026-08-24", "date": "2026-08-20" }`. `occurrence_date` must be the current `date_next`; `date` is the register date and may be the client's local today for YNAB-style Enter Now. Response data contains `transaction`, the advanced `scheduled_transaction`, `occurrence_date`, `entered_date`, `completed`, `replayed`, and `server_knowledge`. A one-off (`never`) schedule returns its deleted tombstone and `completed: true`.

An owner or the default-plan API token can explicitly catch up all due schedules with `POST /v1/plans/{plan_id}/scheduled_transactions/materialize` and body `{ "through_date": "2026-08-24" }`. Response data contains `through_date`, `occurrences`, `skipped_closed_schedule_ids`, and `server_knowledge`. The action preflights the complete batch, enters every missed recurrence, leaves schedules in closed accounts untouched, and has a 5,000-occurrence safety limit.

Materialised transactions use deterministic occurrence IDs and immutable receipts, so retries do not duplicate register rows. They are unapproved and uncleared except in cash accounts, where they are cleared. Parent and split transfers create paired ledger legs; each leg's cleared state follows its own account type. Month recurrences retain the original day anchor, including returning to the 31st after a shorter month; twice-monthly schedules use the chosen day and a second date exactly 15 days later. Schedule advancement uses a compare-and-set snapshot and never overwrites a concurrent user edit.

Production invokes a separate, private automatic materialiser at `16:05 UTC` each day (`00:05 Asia/Singapore`). It is not the owner bulk route: each invocation is capped at 25 occurrences, takes one stable-order due occurrence per schedule before starting another round, re-reads the schedule before entry, and continues past an invalid schedule. Its count-only Worker log reports occurrence, closed-skip, failure, and remaining-work counts; no schedule or transaction payloads are logged. A retry uses deterministic daily and per-occurrence seeds and never duplicates already committed rows. Preview has no cron, so it remains an explicit verification environment. The Worker cron is HowMuch-only and never reads a YNAB token or starts a YNAB sync.

### Imported read-only collections

The following GET endpoints return exact objects from the imported YNAB mirror. They have no HowMuch mutation endpoint yet:

- `GET /v1/plans/{plan_id}/payee_locations`
- `GET /v1/plans/{plan_id}/money_movements`
- `GET /v1/plans/{plan_id}/money_movement_groups`
- `GET /v1/plans/{plan_id}/months/{month}/money_movements`
- `GET /v1/plans/{plan_id}/months/{month}/money_movement_groups`

### Transactions

List:

`GET /v1/plans/{plan_id}/transactions`

Supported query parameters:

- `since_date`
- `until_date`
- `type`
- `last_knowledge_of_server`
- `limit` — whole number from 1 to 250; defaults to 100
- `offset` — zero-based whole-number offset; defaults to 0

Transaction lists are always bounded, including the account, payee, category,
and month-scoped variants. Results are ordered newest first by date, creation
time, and transaction ID. The response retains the `transactions` array and
adds `has_more` plus `next_offset` (an integer or `null`) so clients can load
older pages without requesting an unbounded ledger.

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

The body is `{ "transaction": { ... } }` or `{ "transactions": [ ... ] }`, not both.
A `transactions` array may contain at most 100 items. An empty array is `400`.
Many-create returns `201` with `transaction_ids`, `transactions`,
`duplicate_import_ids`, and `server_knowledge`. An item whose `import_id`
already exists on that account is listed in `duplicate_import_ids` and is
not inserted.

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

If a single create request includes an `import_id` that already exists for the plan, the API returns the existing transaction rather than creating a duplicate. A new `import_id` always inserts, even when account, date, amount, and payee match an existing row. Bulk `POST /transactions/import` still fuzzy-matches those fields. This makes retrying OpenClaw and iOS writes safe without collapsing two identical same-day captures.

Collection update:

`PATCH /v1/plans/{plan_id}/transactions`

```json
{
  "transactions": [
    { "id": "txn-1", "memo": "CLAIMED" },
    { "import_id": "source-unique-id", "account_id": "account-id", "approved": true }
  ]
}
```

Each item must include exactly one of `id` or `import_id`. `import_id` is a
lookup field and never changes the stored import id. `account_id` disambiguates
an `import_id` that exists in more than one account. An ambiguous lookup is
`400`. The array may contain at most 100 items. An empty array is `400`. A
missing target is `404` and SQLite applies none of the batch. The response is `200` with
`transaction_ids`, `transactions`, and `server_knowledge`. SQLite bumps
knowledge once for the batch. D1 applies items sequentially and returns the
final `server_knowledge`.

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
