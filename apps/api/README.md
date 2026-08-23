# HowMuch API

Shared ledger, import, report, and HTTP code for two runtimes: local Bun/SQLite and hosted Cloudflare Worker/D1. `/v1` is the YNAB-compatible surface; `/api` provides reports, imports, and quick entry.

```sh
bun run api:dev
bun test apps/api/tests
```

SQLite applies `migrations/001`–`014`; D1 applies `d1-migrations/0001_initial.sql` through `0011_personal_api_tokens.sql`. The D1 payee schema deliberately permits distinct YNAB payee IDs to share a display name. The raw-object mirror preserves imported YNAB fields that are not yet normalised, including monthly targets, scheduled transactions, locations, and money movements. Imported rows remain immutable: category assignments, targets, and scheduled-transaction changes live in separate guarded overlays. Scheduled transactions support HowMuch-local CRUD plus explicit, idempotent Enter Now and bounded owner catch-up through the effective `/v1` view. Account reconciliation has a read-only preview plus an exact, idempotent `POST /v1/plans/{plan_id}/accounts/{account_id}/reconcile` write, requiring a statement date, integer statement balance, and `Idempotency-Key`. Browser authentication uses a secure session cookie, native clients use opaque bearer sessions, and plan membership is enforced at the HTTP boundary. Signed-in browser users can create and revoke long-lived personal API tokens whose raw values are shown once and never stored; `HOWMUCH_API_TOKEN` remains for one-time owner setup and default-plan integrations.

Production can temporarily run in an explicitly authorised YNAB-primary transition mode. Only the literal `HOWMUCH_TRANSITION_READ_ONLY=true` enables it. The shared HTTP boundary then returns `423 transition_read_only` for the enumerated financial mutations while keeping authentication and reads operational. The Worker routes only `10 16 * * *` to the fenced YNAB delta runner in this mode, giving a daily `00:10 Asia/Singapore` sync; it never calls scheduled materialisation. Preview and local development remain writable and have no YNAB cron or credentials.

The D1 runner passes the saved `last_knowledge_of_server` cursor, advances it only in the atomic successful completion transition, leaves it unchanged after failure, and deduplicates replayed scheduled invocations. Logs expose only structured status, run ID, counts, and cursor—not YNAB response bodies or financial details. A current private D1 Time Travel bookmark is required before enabling or changing the production transition. See `docs/deployment.md` for privacy-safe verification and the exact cutover order: stop YNAB writes, verify the final delta, disable the YNAB cron, remove `HOWMUCH_YNAB_TOKEN`, unlock HowMuch, then restore the `00:05` scheduled-materialisation cron.
