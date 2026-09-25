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

Signed-in browser users manage long-lived personal credentials at `GET`/`POST /api/auth/personal-tokens` and `DELETE /api/auth/personal-tokens/{id}`. Creation returns the `hm_pat_…` bearer value once; HowMuch stores only its SHA-256 fingerprint. Personal tokens inherit the user's current plan memberships, remain valid until revoked, and cannot create or manage other tokens. Management requires the secure browser session and same-origin checks; the global integration token and native bearer sessions are not accepted.

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

`GET /v1/plans/{plan_id}/accounts/usage`

`POST /v1/plans/{plan_id}/accounts`

`PUT /v1/plans/{plan_id}/accounts/{account_id}`

`PATCH /v1/plans/{plan_id}/accounts/{account_id}`

`POST /v1/plans/{plan_id}/accounts/{account_id}/reconcile`

Create body: `{ "account": { "name": "Savings", "type": "savings", "balance": 0, "icon": "💰" } }`.
`icon` is optional. A leading emoji on `name` is lifted into `icon` and
stripped from the stored name. A trailing emoji stays on the name. Accounts
without a leading emoji receive a type default such as 🏦 for checking or 💳
for credit cards.

Update body: `{ "account": { "icon": "🐷", "name": "Everyday", "type": "savings" } }`.
Supply `icon`, `name`, `type`, or any combination. `type` is optional and must
be one of the HowMuch account kinds. `on_budget` is derived from `type` and is
rejected if sent. `icon` must be a single emoji; `name` is stored as typed and
does not lift a leading emoji. A name change also renames the matching
`Transfer : …` payee. A type change that omits `icon` follows the new type
default when the stored icon is missing or still the old type default. Name
and icon writes stay presentation-only and are not locked by transition
read-only mode. A write that includes `type` is locked in transition
read-only mode.

The server generates an id when none is supplied and treats `balance` as the opening
balance. Every account also owns a `Transfer : <name>` payee (created on demand
and backfilled by migration), exposed through `transfer_payee_id`. Account
records include `icon` alongside `name`.

Count recent per-account activity with:

```http
GET /v1/plans/{plan_id}/accounts/usage?days=30&until=2026-08-31
```

This read-only route answers "most used in the last N days" with one grouped
query instead of a paginated register scan. Response data contains `usage`
(`{ account_id, count }` ordered by `account_id`), `days`, `since`, `until`, and
`server_knowledge`.

`days` is an integer from 1 to 366 and defaults to 30. `until` is an ISO date
and defaults to the current UTC date; the window is the inclusive range
`since`..`until`, where `since` is `until` minus `days - 1` days. Clients that
mean their own local "today" should pass `until` explicitly, which is what the
web client does — the day boundary stays client-defined.

A count is one live transaction row of the plan dated inside the window. Each
leg of a transfer therefore counts in its own account, a split parent counts
once (its subtransactions are not separate rows and are never counted), deleted
rows are excluded, scheduled transactions are excluded until they materialise,
and rows dated after `until` are excluded. Accounts with no rows in the window
are absent from `usage` rather than listed with a zero.

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
- `q` — optional free-text needle, 1–200 characters after trimming. A row
  matches when `q` is a case-insensitive substring of its payee, memo,
  category or account name, or of any split line’s payee, memo or category;
  or when `q` parses as a money amount at the typed precision. `142` matches
  142.00–142.99; `142.30` and `$142.30` match 142.30. A leading `-` restricts
  to outflows, `+` to inflows. `q` composes with every other filter by AND.
  Page size, ordering, `has_more` and `next_offset` are unchanged. Omit `q`
  for the unfiltered register page.

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

Unapproved count:

`GET /v1/plans/{plan_id}/transactions/unapproved_count`

`GET /v1/plans/{plan_id}/accounts/{account_id}/transactions/unapproved_count`

Returns `{ "data": { "count": 12, "server_knowledge": 4821 } }`. `count` is the
number of live, unapproved transactions in scope — the same rows
`?type=unapproved` lists, counted rather than returned. `since_date` and
`until_date` narrow it exactly as they narrow the list, and the account-scoped
path narrows it to one account, so a badge drawn from this endpoint always
agrees with the queue the user then opens. `limit`, `offset`, `q` and
`last_knowledge_of_server` do not apply — this is always a count of live rows.

The count and `server_knowledge` are read in one batch, so the number is always
labelled with the knowledge value it was counted at. Clients show the "New"
badge from this and load the queue rows only when the approval flow is opened,
instead of paging the whole queue before the register is usable.

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
not inserted. The matching existing id still appears in `transaction_ids`.

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
    { "import_id": "source-unique-id", "approved": true }
  ]
}
```

Each item must include `id` or `import_id`. If both are present, `id` is the
lookup and `import_id` is ignored. `import_id` never changes the stored import
id. Collection PATCH ignores `deleted`. Use `DELETE` to tombstone a row. A live
`import_id` that matches more than one row is `400`. The array may contain at
most 100 items. An empty array is `400`. A missing target is `404`
and SQLite applies none of the batch. The response is `200` with
`transaction_ids`, `transactions`, and `server_knowledge`. SQLite bumps
knowledge once for the batch.

Bulk cleared and bulk delete:

- `POST /v1/plans/{plan_id}/transactions/cleared`
- `POST /v1/plans/{plan_id}/transactions/delete`

These are bounded commands of at most 100 items, for register bulk actions that
must keep the single-row guards. They are deliberately **not** all-or-nothing:
D1 commits each row as its own guarded command, so a command can stop partway.
The response is `200` with an ordered `outcomes` array — one entry per requested
row, in request order — plus `applied_count`, `conflict_count`,
`already_removed_count`, `unresolved_count`, `unattempted_count`, and
`server_knowledge`. Duplicate ids are rejected with `400` before anything is
written, because a repeated id would apply twice in one command and report a
second, misleading outcome.

```json
{
  "transactions": [
    { "id": "txn-1", "expected_cleared": "uncleared", "cleared": "cleared" }
  ]
}
```

Cleared items each repeat the single-item body plus `id`, so every row keeps its
own `expected_cleared` compare-and-set and its own reconciled-state protection.
Delete items are `{ "id": "...", "expected_approved": false }`; the guard is
optional and never inferred. A transfer leg or split node still cascades to its
linked side, exactly as the single-row routes do.

Outcome statuses are:

- `applied` — the server confirmed this row's own write. This is the only status
  that counts as work the command did.
- `conflict` — an expected-state precondition failed. This item's write was not
  applied, and the command continues to the next item.
- `already_removed` — the row was already gone when this item was reached. This
  is an observation, not an attribution: a transfer pair this command cascaded
  to, a row another client deleted, and an id that never existed all look the
  same here, so the command never claims it removed the row and never counts it
  as its own work. An item whose own command conflicted and that a later sibling
  delete then cascaded over stays `conflict`; a sound cascade report would
  require the owning command to return the ids it actually committed.
- `unresolved` — an infrastructure or ambiguous failure. The write may or may
  not have landed; the command stops here and the caller must refetch. Nothing
  is replayed, and the detail is a generic message rather than raw
  infrastructure text.
- `unattempted` — never sent, because the command stopped at an earlier failure.

The collection PATCH remains the route for bulk categorisation and approval. It
has no per-item outcomes, so a client that chunks it must treat a failed chunk
as uncertain rather than assuming it applied cleanly, and must read the returned
rows back — a `200` does not by itself mean the requested category survived the
server's normalisation. The web client reports a category mismatch as a local
`conflict` outcome (for example, when a row has become a split parent or
transfer). This is derived from the returned category, not a server-provided
PATCH outcome or a guarantee that the row was left unchanged.

Individual transaction:

- `GET /v1/plans/{plan_id}/transactions/{transaction_id}`
- `PUT /v1/plans/{plan_id}/transactions/{transaction_id}`
- `PATCH /v1/plans/{plan_id}/transactions/{transaction_id}`
- `DELETE /v1/plans/{plan_id}/transactions/{transaction_id}`

The register's cleared-state toggle uses
`PATCH /v1/plans/{plan_id}/transactions/{transaction_id}/cleared` with a body
such as `{ "expected_cleared": "uncleared", "cleared": "cleared" }`. Both
values must be `uncleared` or `cleared`. The update changes only that ledger
side, including for transfers, and returns `409 transaction_state_conflict` if
the live state no longer matches `expected_cleared`. Reconciled transactions
cannot be changed back through either update route.

Review clients reject new rows with
`DELETE /v1/plans/{plan_id}/transactions/{transaction_id}?expected_approved=false`.
The delete is atomic and returns `409 transaction_state_conflict` if another
client approved the transaction after it was loaded. Omitting the query
parameter retains the ordinary unconditional delete behavior.

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

`GET /api/reports/rewards`

Rewards reads imported Rewards Tracker cards and the HowMuch ledger. It does not call YNAB. Spend and reward figures are currency units, not milliunits.

Rewards has two date modes:

- **No `from`:** each card's own current calendar, billing, promotional or anchored reward period, evaluated as of `to` (or today). `as_of` is clamped to today's **Asia/Singapore** date; future purchases never earn early.
- **With `from`:** historical attribution from that date through `to` (or today). Calculations retain the complete history within each actual reward period before attributing rewards to the selected transactions. A range boundary does not reset caps, minimums or spending tiers.

Dates must be real `YYYY-MM-DD` dates and `from` must not follow an explicit `to`; invalid values return 400. Account filters select cards. Reward rules use transaction flags, not the general report category/transfer filters described below.

The response retains `cards`, `groups`, `totals`, `from`, `to`, `group_by` and `miles_valuation`, and adds:

- `as_of` and a human-readable `period` label.
- `transaction_rewards[id] = { reward, reward_dollars }` for every selected transaction, including explicit zeros for non-earning rows and refunds. Missing IDs are outside the selected accounts/date windows. `reward` is native miles or cashback; `reward_dollars` applies miles valuation, including a valuation of zero.
- Each card's calculation exposes `qualification_status` (`not_required`, `met`, `pending`, `failed`), optional `monthly_minimum_spend`, and optional `monthly_qualifications`: `{ start, end, spend, minimumSpend, status }` (the nested `minimumSpend` retains the engine's camelCase spelling).
- Tier state: `active_spending_tier_id`, `has_next_spending_tier`, `next_spending_tier_id`, `next_spending_tier_threshold`, `should_stop_using`. Hitting a cap while another tier is available does not set `should_stop_using`.
- `calculation.periods[] = { start, end, calculation }` contains full-period totals and qualification context. Top-level card amounts are attributed to the selected range; top-level qualification/progress describes the cutoff period. Do **not** sum the nested full-period amounts: calendar windows can overlap a one-off promotional window. The top-level totals and transaction map already handle attribution.

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
- `group` on Rewards (`flag`, `payee`, `category`, `memo`)

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

`POST /api/import/rewards-tracker`

Accepts a Rewards Tracker for YNAB settings export (`cards` required). Official Settings exports are the Cloud Sync portable payload: cards, rules, tag mappings, theme groups, hidden cards, and budget selection. Older localStorage dumps may also include `cachedData` with YNAB-shaped accounts, flag names, and dashboard transactions. Those objects are upserted through the same ledger IDs the tracker already syncs over `/v1`. Secrets (`pat`, `howmuchToken`, Cloud Sync phrases, formatter API keys) are stripped. Replaying the same file updates existing cards and transactions instead of duplicating them.

Legacy `points` configurations migrate to miles; absent earning rates use the first active legacy rule's rate or the tracker's default. Explicit modern null/zero rates are preserved. Cached transaction omissions preserve existing fields; explicit nulls clear nullable metadata, and tombstones remain deleted. Name-only cached categories reuse a unique matching ledger category or receive a stable plan-scoped imported identity; existing matched transaction category IDs remain authoritative. This preserves purchase-refund versus inflow classification without inventing source category IDs.

Import replaces the stored card set: omitted cards are removed, and `cards: []` removes all cards. Export configuration before replacing it. A portable configuration export contains no transaction history; importing it alone does not migrate the ledger.

`GET /api/import/rewards-tracker`

Returns the stored portable snapshot and live cards for the plan.

`GET /api/rewards/accounts/:accountId/config?plan_id=...`

Returns `{ "data": { "format": "rewards-account-config", "version": 1, "card": { ... } } }`.
The downloadable file is the `data` object. `card` uses the allowlisted `CreditCard`
configuration fields below, excluding `id`, `ynabAccountId` and `featured`. Nested
subcategory/tier IDs remain for tier references. No transactions, global settings or
credentials are exported. Missing accounts or configuration return 404; multiple
cards on the same account return 400 rather than choosing arbitrarily.

`PUT /api/rewards/accounts/:accountId/config`

Body: `{ "plan_id"?: string, "payload": { "format": "rewards-account-config", "version": 1, "card": { ... } } }`.
Requires a live destination account. Replaces only its rewards configuration,
clearing omitted optional fields, while preserving its existing card ID, name,
account link and featured preference. Creates a card named after the account if
none exists. Other cards, global settings and all ledger rows are unchanged.
Returns `{ "data": { "card" } }`; repeated imports reuse the destination card ID.
Malformed format/version/configuration, duplicate category/tier IDs, repeated flag
colours or tier override references, and dangling tier references return 400.
Account not found returns 404. Normal plan authorization
and cookie CSRF checks apply. `name`, string `issuer` (may be empty), and
`type: "cashback" | "miles"` are required in the file. Numeric/date rules match
card writes below; boolean fields must be booleans. Optional `flagNames` maps
supported colours (including `unflagged`) to strings and is card metadata, not a
request to rewrite transaction labels. Currency-unit amounts are not converted.
Unknown properties are discarded recursively through known-field projection.

`POST /api/rewards/cards`

Creates a Rewards Tracker card mapped to a live HowMuch account. Body is `{ "plan_id"?: string, "card": { ... } }`. If `card.id` is omitted, the server assigns one. Native writes allowlist the `CreditCard` fields and strip secrets (`pat`, `howmuchToken`, Cloud Sync fields, cached data). Unknown or missing `ynabAccountId` returns 422. Closed accounts are still live. Returns `201 { "data": { "card" } }`.

Rates, spend limits and block sizes must be finite and nonnegative. Repeating reward periods require integer `monthCount` from 2 through 24 and a real anchor date; billing days are integers from 1 through 31. Promotional dates must be real and ordered. Additional tier thresholds must be unique. Card/tier optional rates and limits accept null; category and category-override rates require numbers. `subcategoriesEnabled` is independent of retained category definitions.

`PATCH /api/rewards/cards/:id`

Merges the supplied card fields onto the live card. Missing cards return 404. Unknown or missing `ynabAccountId` after the merge returns 422. Returns `{ "data": { "card" } }`.

`DELETE /api/rewards/cards/:id`

Soft-deletes the card (`deleted = 1`) and removes that id from the stored snapshot card list. Returns `{ "data": { "card" } }` of the deleted payload, or 404. Does not replace the snapshot with an empty cards array.

`PATCH /api/rewards/settings`

Merges `milesValuation` (a finite nonnegative number, including zero) into the stored Rewards Tracker settings without replacing cards. Other body keys, including Cloud Sync secrets, are ignored. Returns `{ "data": { "settings" } }` parsed as app settings.

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

### Category suggestions (Jev)

`POST /api/tools/categorise?plan_id=...`

Suggests a category per transaction using TypeSafe's Jev model. Requires
authentication and write access to `plan_id`; cookie sessions also pass the usual
same-origin check, and bearer clients (iOS, personal tokens) may call it. The
TypeSafe key is the server's `TYPESAFE_API_KEY` secret and never reaches clients.
Nothing is written: apply accepted suggestions through the transaction PATCH.

Body: `{ transactions: [{ key?, payee_id?, payee_name?, memo?, amount, date?,
account_name? }] }`, 1 to 25 items, `amount` in signed milliunits, each with a
payee name or memo. `key` defaults to the item's index.

Returns `{ data: { model, usage, suggestions: [{ key, suggestion, confidence,
alternatives }] } }`. `suggestion` is `{ category_id, category_name, group_name,
probability }`, or `null` when Jev chose "none of these". `alternatives` lists up
to three other categories by probability. `confidence` describes how concentrated
Jev's distribution was, not whether the answer is correct.

Jev chooses only among the plan's live, visible categories (plus inflow
categories; credit card payment categories are excluded), so payee or memo text
cannot make it return anything else. As evidence, each item carries the category
counts from that payee's last 50 transactions and up to eight distinct categorised
past transactions whose payee or memo contains the payee's most distinctive word
(so "GRAB*RIDES 1234" finds earlier "Grab" rows). Jev judges which examples are
relevant. The request sends payee names, memos, amounts, dates, account names,
category names and those past examples to TypeSafe. Errors: `503 categoriser_not_configured` without a key,
`502 categoriser_unavailable` when TypeSafe fails or rejects the key,
`429 categoriser_rate_limited`.

**Automatic categorisation on create.** When `TYPESAFE_API_KEY` is set,
`POST /v1/plans/{plan_id}/transactions` (single and batch) and
`POST /api/mobile/quick-entry` ask Jev for a category for each new transaction
that names a payee (`payee_name` or `payee_id`) but no `category_id`. Jev's pick is
stored only when its confidence is at least 0.6 and it is not "none of these";
otherwise the transaction is created uncategorised. Transfers, splits and rows with
an explicit category are never changed. The step is best effort: it has a 5-second
budget with no retries, and a slow or failing TypeSafe never fails the create.
A create that repeats an existing transaction id (a retry) keeps that row's stored
category and does not call Jev again. Imports, CSV uploads and scheduled
materialisation are not auto-categorised.

### AI-assisted reward tools

Both routes require authentication, same-origin CSRF validation and write access to
`plan_id`. Keys are transient and requests use fixed provider endpoints, without
fallbacks. Neither route persists keys, drafts, images or extracted rows.

`POST /api/tools/reward-terms?plan_id=...`

Body: `{ provider: "openai" | "openrouter" | "opencode", apiKey, model,
cardType: "cashback" | "miles", terms?, url?, instructions?, consent: true }`.
Returns `{ data: { raw } }` containing validated model JSON. URL fetching permits
only the exact bank HTTPS hosts listed in the UI; redirects and PDFs are rejected.
Paste text for other sources. The browser compiles the draft against the selected
card, shows the proposed categories/limits/tiers, and requires an explicit save
through the normal card PATCH endpoint. Notes do not become executable rules.
Null/omitted card limits and bucket minimum/maximum spend or block size preserve
matched existing values (normalized name, or unflagged default identity); zero
remains explicit. An omitted catch-all preserves the existing unflagged rule's
rate/constraints, otherwise uses the proposed/preserved card base rate.
Null/omitted `spendingTiers` preserves existing tier IDs and relinks overrides;
`[]` removes tiers. Explicit tiers replace them and can include
`subcategories: [{ name, rewardValue, maximumSpend? }]`: unique normalized bucket
names are resolved to compiled IDs; unknown/duplicate references are rejected.
A nonnull tier `earningRate` overrides the default bucket rate (retaining its cap)
unless explicitly overridden; named buckets retain their rates unless overridden.
Null/omitted tier `earningRate` adds no default override. Explicit tier category
overrides require a nonnegative rate; their null/omitted cap means no cap, zero
also means unlimited, and positive caps limit eligible spend. Tier card caps use
the same null/zero/positive semantics. Overrides retain category minimums, blocks,
and exclusions; tier nulls do not preserve values from replaced tiers.

`POST /api/tools/statement-formatter?plan_id=...`

Body: `{ provider: "gemini" | "openai" | "openrouter", apiKey, model,
image: "data:image/...;base64,...", instructions?, consent: true }`.
Accepts PNG, JPEG or WebP, up to 5 MiB per image. Returns
`{ data: { rows: [{ date, payee, memo, outflow, inflow }] } }`.
The browser handles sequential images, cancellation, review and CSV export;
this endpoint does not import transactions. Consent is mandatory for both tools.
