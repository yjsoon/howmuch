# OpenClaw Compatibility Matrix

Date: 2026-06-11

Scope: transaction ingestion and adjacent lookup/update behaviour needed for a Claw/OpenClaw-style agent to target HowMuch as a drop-in-ish YNAB replacement. This intentionally excludes envelope budgeting, goals, scheduled transactions, loans, payee locations, and other YNAB surfaces not used by the current ingestion scripts.

Sources:

- Official YNAB API docs at `https://api.ynab.com/` and endpoint docs at `https://api.ynab.com/v1`.
- Prior HowMuch backend thread findings from OpenClaw scripts on a personal machine.
- Local implementation under `apps/api/src`, `apps/api/tests`, `scripts/smoke.ts`, and `docs/research/ynab-usage-audit.md`.

## Matrix

| OpenClaw / YNAB need | Implemented endpoint / field | Evidence | Gap or risk | Recommended fix |
| --- | --- | --- | --- | --- |
| Bearer auth and YNAB error envelope | Static bearer token via `HOWMUCH_API_TOKEN`; errors return `{ error: { id, name, detail } }` | `apps/api/src/http.ts`, `apps/api/tests/api.test.ts` | OAuth is not implemented, but OpenClaw uses token-style server calls | Set `HOWMUCH_API_TOKEN` for non-local use; no OAuth needed for current OpenClaw |
| Current `/plans` paths plus legacy `/budgets` aliases | `GET /v1/plans`, `GET /v1/budgets`, and both collection aliases for core resources | `apps/api/src/http.ts`, `docs/api-contract.md` | Old clients get legacy top-level `budget(s)` only for plan list/single-plan routes; nested resource keys match YNAB resource names | No blocker |
| Account lookup before ingestion | `GET /v1/plans/{plan_id}/accounts`, `GET /v1/budgets/{budget_id}/accounts`, single account read | `apps/api/src/http.ts`, `apps/api/src/repository.ts` | Account creation is local-friendly but not a complete YNAB account API clone | Seed or import real account ids before switching OpenClaw |
| Payee lookup and creation | `GET /v1/plans/{plan_id}/payees`, `POST /v1/plans/{plan_id}/payees` | `apps/api/src/http.ts`, `apps/api/src/repository.ts`, `docs/research/ynab-usage-audit.md` | Fuzzy matching remains in OpenClaw scripts, not the API | No blocker; keep script-side fuzzy logic |
| Payee latest-transaction category reuse | `GET /v1/plans/{plan_id}/payees/{payee_id}/transactions` | `apps/api/src/http.ts`, `apps/api/tests/api.test.ts` | Ordering is newest first by transaction date/created time | No blocker |
| Category lookup for classification | `GET /v1/plans/{plan_id}/categories`; transaction rows include `category_id` and `category_name` | `apps/api/src/http.ts`, `apps/api/src/repository.ts` | Category assignment fields are compatibility placeholders rather than envelope-budget values | No blocker for ingestion |
| Category-scoped transaction reads | `GET /v1/plans/{plan_id}/categories/{category_id}/transactions` | `apps/api/src/http.ts`, `apps/api/tests/api.test.ts` | Only parent transaction `category_id` is matched; split category filtering does not yet include subtransactions | Not blocking OpenClaw ingestion; improve if report/debug clients need split-scoped category reads |
| OpenClaw transaction create payload | `POST /v1/plans/{plan_id}/transactions` accepts `account_id`, `date`, milliunit `amount`, `payee_id`, `payee_name`, `category_id`, `memo`, `flag_color`, `cleared`, `approved`, and splits | `apps/api/src/http.ts`, `apps/api/src/repository.ts`, `apps/api/tests/api.test.ts` | The API trusts caller date/amount normalisation on `/v1`, matching YNAB | No blocker |
| Idempotent writes by import id | Single `POST /transactions` now returns an existing transaction for a repeated `import_id`; bulk `POST /transactions/import` returns duplicate ids | `apps/api/src/http.ts`, `apps/api/src/repository.ts`, `apps/api/tests/api.test.ts` | Existing OpenClaw scripts usually do their own duplicate check and may not send `import_id` everywhere | Add stable `import_id` in OpenClaw when practical; HowMuch is ready for it |
| Script-side fuzzy duplicate checks | Transactions can be listed by plan/account/payee/category/month with `since_date`, `until_date`, and `type` filters | `apps/api/src/http.ts`, `apps/api/src/repository.ts` | The API does not expose a dedicated duplicate-search route | No blocker because current OpenClaw already performs read-then-create checks |
| Incremental sync / server knowledge | `server_knowledge` returned on core list/mutation responses; transaction deltas support `last_knowledge_of_server`, including deleted tombstones | `apps/api/migrations/002_transaction_server_knowledge.sql`, `apps/api/src/repository.ts`, `apps/api/tests/api.test.ts` | Deltas are transaction-level only; account/category/payee delta filtering is not fully modelled | Not blocking ingestion; sufficient for transaction pollers |
| Deleted transaction rows | `DELETE /v1/plans/{plan_id}/transactions/{transaction_id}` marks deleted and delta reads include tombstones | `apps/api/src/http.ts`, `apps/api/src/repository.ts`, `apps/api/tests/api.test.ts` | Subtransaction deletion is only represented through the parent transaction | No blocker |
| Memo updates for claim/receipt workflows | Item `PUT`/`PATCH` plus collection `PATCH /v1/plans/{plan_id}/transactions` (up to 100 rows, by `id` or `import_id`) | `apps/api/src/http.ts`, `apps/api/src/repository.ts`, `apps/api/tests/api.test.ts` | Collection PATCH is the YNAB bulk path | Use collection PATCH when several memos change in one request |
| Cleared and approved flags | Transaction create/update persist `cleared` and `approved`; default is `uncleared` and not approved | `apps/api/src/repository.ts`, `apps/api/src/types.ts` | Defaults may differ from a script's expectation if it assumes YNAB UI defaults | If OpenClaw wants imported transactions reviewed, send `approved: false`; otherwise send explicit `approved: true` |
| Flag colours and custom flag names | Transaction rows persist `flag_color` and `flag_name`; settings exposes `display.flag_names` | `apps/api/src/repository.ts`, `apps/api/src/http.ts` | No UI for editing flag-name settings yet | No blocker for ingestion |
| Split transactions | Create/update/list preserves `subtransactions`; reports expand split lines | `apps/api/src/repository.ts`, `apps/api/src/reports.ts`, `apps/api/tests/api.test.ts` | Transfers with paired split transaction semantics are stored but not auto-generated | No blocker for current OpenClaw writes, which are mostly unsplit card transactions |
| Transfers | Fields exist for `transfer_account_id`, `transfer_transaction_id`, and transfer payees | `apps/api/src/repository.ts`, `docs/api-contract.md` | The API does not auto-create the counterparty transfer transaction | Avoid relying on automatic YNAB transfer pairing until implemented |
| YNAB CSV/OCR fallback | `POST /api/import/csv` accepts `date`, `payee`, `memo`, `outflow`, `inflow`, row-level account ids, duplicate detection | `apps/api/src/importers/csv.ts`, `apps/api/tests/api.test.ts`, `scripts/smoke.ts` | Native endpoint, not YNAB-compatible `/v1` | No blocker; useful for `ynab-formatter` style imports |
| Full-history YNAB migration | `POST /api/import/ynab` fetches accounts, categories, payees, and transactions with default `since_date=1900-01-01` | `apps/api/src/importers/ynab.ts`, `apps/api/tests/api.test.ts` | Not verified against a live YNAB token in this worktree | Run once with a real token in a private environment before final cutover |

## Verdict

HowMuch has the backend/API surface needed for current OpenClaw transaction ingestion. The two blocking compatibility risks found in this audit were fixed here:

- Repeated single transaction writes with the same `import_id` no longer create duplicates.
- Error bodies now use the YNAB-style `id`, `name`, and `detail` fields.

The remaining risks are operational or future-depth items, not blockers for pointing a Claw at HowMuch:

- Seed or import real account, payee, and category ids before switching OpenClaw.
- Add stable OpenClaw `import_id` values to scripts that do not send them yet.
- Do not rely on automatic transfer-pair creation until that is explicitly implemented.
- Verify one real YNAB import with a private token before treating the migration path as production-ready.
