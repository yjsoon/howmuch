# YNAB API comparison

Reference against YNAB OpenAPI 1.86.0 (`https://api.ynab.com/papi/open_api_spec.yaml`, `https://api.ynab.com/v1`), checked 2026-08-23. HowMuch routes are those dispatched in `apps/api/src/http.ts`.

HowMuch keeps `/v1/plans/{plan_id}/...` and `/v1/budgets/{budget_id}/...` for the same resources. YNAB documents `/plans` and still accepts `/budgets`.

## Transaction writes

| YNAB | HowMuch |
| --- | --- |
| `POST /plans/{plan_id}/transactions` with `{ transaction }` or `{ transactions }` | Single `{ transaction }` plus `{ transactions }` up to `MAX_TRANSACTION_WRITE_BATCH` (100) |
| `PATCH /plans/{plan_id}/transactions` updates many rows by `id` or `import_id` | Same path, same lookup rules, same cap |
| `PUT /plans/{plan_id}/transactions/{transaction_id}` | Same, and HowMuch also accepts `PATCH` on the item |
| `DELETE /plans/{plan_id}/transactions/{transaction_id}` | Same |
| `POST /plans/{plan_id}/transactions/import` starts bank import | HowMuch accepts a client-supplied `transactions` array on this path |

YNAB collection PATCH treats `import_id` as lookup only. HowMuch does the same. Live import ids are unique on `(plan_id, account_id)`.

## Transaction reads

| YNAB | HowMuch |
| --- | --- |
| `GET` plan, account, category, payee, and month scoped lists | Same paths |
| `since_date`, `until_date`, `type`, `last_knowledge_of_server` | Same |
| Unbounded list. Omitted `since_date` defaults to one year ago | Bounded pages. `limit` 1-250, default 100. Response includes `has_more` and `next_offset` |
| `GET /transactions/{transaction_id}` | Same |

## Other `/v1` resources

| Resource | YNAB | HowMuch |
| --- | --- | --- |
| `GET /user` | Authenticated user | Session user or `{ id: "local-user" }` for the static token |
| `GET /plans` | List. `include_accounts` query | List. No `include_accounts` |
| `GET /plans/{plan_id}` | Full plan export. `last-used` and `default` aliases | Plan summary from `formatPlan`. No `last-used` alias |
| `GET /plans/{plan_id}/settings` | Settings | Settings including `display.flag_names` |
| Accounts `GET`/`POST` collection, `GET` item | Yes | Yes, plus reconciliation preview and `POST .../reconcile` |
| Categories `GET` groups | Yes | Yes |
| Categories `POST` collection, `GET`/`PATCH` item | Yes | No |
| `GET`/`PATCH` month category | Yes | `PATCH` only, as a HowMuch overlay |
| Category groups `POST`/`PATCH` | Yes | No |
| Payees `GET`/`POST` collection, `GET`/`PATCH` item | Yes | Collection `GET`/`POST` only. Item `GET`/`PATCH` are absent |
| Payee locations `GET` collection, item, and payee-scoped | Yes | Collection `GET` from the imported raw mirror. Item and payee-scoped `GET` are absent |
| `GET /months` | Yes | No |
| `GET /months/{month}` | Yes | Yes |
| Money movements and groups, plan and month scoped | `GET` | `GET` from the imported raw mirror |
| Scheduled transactions `GET`/`POST` collection, `GET`/`PUT`/`DELETE` item | Yes | Same, plus item `PATCH`, `GET /scheduled_subtransactions`, Enter Now, owner catch-up, and a production cron |

## Auth and errors

YNAB uses bearer OAuth or a personal access token. HowMuch uses a password session cookie, a native bearer session, and a static `HOWMUCH_API_TOKEN` limited to `HOWMUCH_DEFAULT_PLAN_ID`. Error bodies use `{ error: { id, name, detail } }`.

## HowMuch-only `/api`

- `GET /api/reports/spending-breakdown`
- `GET /api/reports/income-vs-spending`
- `GET /api/reports/net-worth`
- `GET /api/reports/age-of-money`
- `POST /api/mobile/quick-entry`
- `POST /api/import/csv`
- `POST /api/import/ynab`
- `POST /api/auth/setup`, `login`, `token`, `logout`

## Verdict for transaction clients

A client that lists, creates, updates, and deletes transactions on YNAB `/v1` paths can point at HowMuch after this change. Collection `PATCH` and collection `POST { transactions }` are the write paths that were missing. Envelope category CRUD, a full plan export, `last-used`, OAuth, and bank-linked import remain YNAB-only. Reconciliation, reports, overlays, and scheduled materialisation are HowMuch-only.
