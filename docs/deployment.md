# Deployment

Production and preview use separate fresh D1 databases in APAC:

- `howmuch-production`: `57dc5569-d639-44c1-bb9d-6214f43a43b8`
- `howmuch-preview`: `7ca818bd-7f04-4b9b-8a84-8c8f84a6a272`

Environment bindings are repeated because Wrangler does not inherit them. Local work may apply the canonical migration with:

```sh
cd apps/worker
wrangler d1 migrations apply DB --local
bun run build
```

The preview environment explicitly enables both its `workers.dev` route and
Preview URLs. This produces a reachable `howmuch-preview.<account>.workers.dev`
endpoint for end-to-end checks while leaving production on
`https://howmuch.soon.sg`.

For a first remote deployment, migrate before deploying:

```sh
cd apps/worker
wrangler d1 migrations apply DB --remote --env preview
bun run deploy:preview
wrangler d1 migrations apply DB --remote
bun run deploy
```

The deployment scripts build the web app immediately before Wrangler uploads
its assets. Use them rather than invoking `wrangler deploy` directly so `/docs`
and the rest of the SPA cannot be missing or stale.

Keep `HOWMUCH_API_TOKEN` as an encrypted secret. Use the local, validated import, parity, and D1-bootstrap tools in `docs/ynab-migration.md` for any YNAB work. They copy the verified ledger, provenance, and raw mirror into an otherwise clean target. Do not use an unverified SQLite file or ad-hoc table copy.

## Temporary YNAB transition mode

Production has an explicitly authorised, temporary YNAB-primary transition configuration. `HOWMUCH_TRANSITION_READ_ONLY=true`, `HOWMUCH_YNAB_PLAN_ID=80bc6db0-d926-4635-a37a-1ba0787c4c4e`, and cron `10 16 * * *` route one daily delta at `00:10 Asia/Singapore`. `HOWMUCH_YNAB_TOKEN` must exist only as an encrypted Worker secret; it must never appear in `wrangler.jsonc`, command output, logs, or verification notes. Preview has `HOWMUCH_TRANSITION_READ_ONLY=false`, no YNAB plan or token, and no cron. Local configuration is writable unless the variable is the literal string `true`.

Before enabling the production secret or deploying a transition configuration, verify Wrangler profile `yj` is using account `YJ` (`810a0c404daff0737f4a2a97a7aab092`) and D1 database `howmuch-production` (`57dc5569-d639-44c1-bb9d-6214f43a43b8`). A current D1 Time Travel bookmark is a required recovery gate. From `apps/worker`, record the private bookmark returned by:

```sh
wrangler d1 time-travel info DB --profile yj --json
```

Do not proceed without a valid bookmark and its timestamp. Keep the bookmark out of public logs and source control.

While transition mode is enabled, YNAB is the only financial writer. After authentication and browser CSRF checks, production returns HTTP `423` with error name `transition_read_only` for transaction create/import/update/delete, mobile quick entry, reconciliation commits, scheduled-transaction create/update/delete/materialisation, account and payee creation, CSV or manual YNAB imports, and month category assignment or target changes. Authentication, reads, health checks, and unrelated unknown unsafe routes keep their normal behaviour. The transition cron never invokes HowMuch scheduled materialisation, which prevents YNAB and HowMuch from entering the same scheduled occurrence.

The scheduled delta resumes from `ynab_sync_state.server_knowledge`. A successful fenced import atomically advances the cursor only after its ledger writes complete; a failed import leaves the cursor unchanged. The stable scheduled run ID and transition receipts make a replay of the same cron invocation a duplicate rather than a second import. Do not reset the cursor or perform a full bootstrap during transition.

Verification must be privacy-safe. Use only the structured `ynab_delta_sync` event (`status`, run ID, transaction/raw-object counts, and cursor) and count/status/cursor queries against `sync_runs`, `sync_attempts`, and `ynab_sync_state`. Do not print transaction rows, YNAB response bodies, tokens, plan names, payees, memos, or stored failure text. Failed scheduled runs retain and throw only the generic `YNAB scheduled sync failed` status; detailed upstream response bodies are neither persisted by the scheduler nor logged.

Final cutover back to HowMuch must happen in this order:

1. Stop every write in YNAB and keep HowMuch locked.
2. Allow the final `00:10` delta to complete, then verify its completed status, counts, cursor advancement, cleared lease, and expected ledger parity without exposing financial data.
3. Remove the YNAB cron from production and deploy that locked, no-cron configuration. Confirm no scheduled trigger remains.
4. Delete the encrypted `HOWMUCH_YNAB_TOKEN` Worker secret and verify it is absent. Remove `HOWMUCH_YNAB_PLAN_ID` from production configuration as part of the cutover change.
5. Set `HOWMUCH_TRANSITION_READ_ONLY=false` and deploy, restoring HowMuch financial writes only after the final delta is verified and YNAB syncing is impossible.
6. Restore only the HowMuch scheduled-materialisation cron `5 16 * * *` (`00:05 Asia/Singapore`) and verify one count-only run. It enters at most 25 fair, re-evaluated occurrences, skips closed accounts, isolates bad schedules, and uses deterministic receipts for retry safety.

After cutover, do not run a YNAB re-import over a ledger with HowMuch-local writes such as account reconciliations unless a new transition and conflict policy has been explicitly authorised; it could replace normalised YNAB-derived transaction state.

After the password-auth migration and Worker are deployed, open the app on its HTTPS custom domain. When no user exists, the setup form requests:

- a username containing 3–64 letters, numbers, dots, underscores, or hyphens;
- a password of at least 15 characters;
- the existing `HOWMUCH_API_TOKEN` as a one-time bootstrap token.

Setup atomically creates the first owner and is permanently disabled once a user exists. Do not put the username or password in deployment commands, source control, or chat. The static API token continues to authorize automation against only `HOWMUCH_DEFAULT_PLAN_ID`.
