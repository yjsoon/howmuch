# Deployment

## Authority and local validation

Remote migrations and deployments require explicit authorization for the selected environment. Use only Wrangler profile `yj`, account **YJ `810a0c404daff0737f4a2a97a7aab092`**, never the Tinkertanker Cloudflare account. The owner's `yjsoon@gmail.com` shorthand and displayed member `cloudflare@yjsoon.com` refer to the same intended account; account/resource IDs, not the email label, are authoritative.

Verify the selected account and that the configured resources exist there before any remote mutation. Do not create replacements or change bindings to work around a wrong account. Production and preview use separate D1 databases in APAC:

| Environment | Worker | D1 database | D1 ID |
|---|---|---|---|
| Production | `howmuch` | `howmuch-production` | `57dc5569-d639-44c1-bb9d-6214f43a43b8` |
| Preview | `howmuch-preview` | `howmuch-preview` | `7ca818bd-7f04-4b9b-8a84-8c8f84a6a272` |

Environment bindings are repeated because Wrangler does not inherit them. Local work may apply the canonical migration with:

```sh
cd apps/worker
wrangler d1 migrations apply DB --local
bun run build
```

The worker `build` script builds web assets and runs `wrangler deploy --dry-run`; it does not upload or authorize a deployment. Local tests/fixes/reruns may continue within the task without production credentials or publication permission.

The preview environment explicitly enables both its `workers.dev` route and
Preview URLs. This produces a reachable `howmuch-preview.<account>.workers.dev`
endpoint for end-to-end checks while leaving production on
`https://howmuch.soon.sg`.

## Authorized remote deployment

After verifying identity/resources, migrate before deploying **only the authorized environment**. Commands below run from `apps/worker`; a preview request does not authorize production.

Preview:

```sh
wrangler d1 migrations apply DB --remote --profile yj --env preview
bun run deploy:preview
```

Production:

```sh
wrangler d1 migrations apply DB --remote --profile yj
bun run deploy
```

Both deployment scripts select profile `yj` explicitly. Profile selection is not a substitute for account/resource verification. They build the web app immediately before Wrangler uploads
its assets. Use them rather than invoking `wrangler deploy` directly so `/docs`
and the rest of the SPA cannot be missing or stale.

Keep `HOWMUCH_API_TOKEN` as an encrypted secret. Use the local, validated import, parity, and D1-bootstrap tools in `docs/ynab-migration.md` for any YNAB work. They copy the verified ledger, provenance, and raw mirror into an otherwise clean target. Do not use an unverified SQLite file or ad-hoc table copy.

## Current YNAB transition status

Production has finished the YNAB-primary transition. `HOWMUCH_TRANSITION_READ_ONLY=false`, there is no `HOWMUCH_YNAB_PLAN_ID`, and the only cron is HowMuch scheduled materialisation at `5 16 * * *` (`00:05 Asia/Singapore`). Do not add `HOWMUCH_YNAB_PLAN_ID` or the `10 16 * * *` YNAB delta cron again unless a new transition is explicitly authorised. `HOWMUCH_YNAB_TOKEN` must not exist as a Worker secret. Preview stays writable with no YNAB plan, token, or cron. Local configuration is writable unless the variable is the literal string `true`.

### Historical procedure — only for an explicitly authorized new transition

The following transition/recovery/cutover steps are not part of routine deployment. Re-evaluate them against current source and an approved conflict policy before any reactivation; this document does not authorize restoring the former transition.

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

## First-owner setup

After the password-auth migration and Worker are deployed, open the app on its HTTPS custom domain. When no user exists, the setup form requests:

- a username containing 3–64 letters, numbers, dots, underscores, or hyphens;
- a password of at least 15 characters;
- the existing `HOWMUCH_API_TOKEN` as a one-time bootstrap token.

Setup atomically creates the first owner and is permanently disabled once a user exists. Do not put the username or password in deployment commands, source control, or chat. The static API token continues to authorize automation against only `HOWMUCH_DEFAULT_PLAN_ID`.
