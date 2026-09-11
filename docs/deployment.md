# Deployment

The D1 databases, all in APAC:

- Production (Tinkertanker account, env `tk`): `howmuch-production` = `df039dbc-6dda-4150-9dc3-5854a8ca6818`
- Legacy frozen backup (YJ account, top-level env): `howmuch-production` = `57dc5569-d639-44c1-bb9d-6214f43a43b8` — never migrate against or write to it
- Preview (YJ account, env `preview`): `howmuch-preview` = `7ca818bd-7f04-4b9b-8a84-8c8f84a6a272`

Environment bindings are repeated because Wrangler does not inherit them. Local work may apply the canonical migration with:

```sh
cd apps/worker
wrangler d1 migrations apply DB --local
bun run build
```

The worker `build` script builds web assets and runs `wrangler deploy --dry-run`; it does not upload or authorize a deployment. Local tests/fixes/reruns may continue within the task without production credentials or publication permission.

The preview environment explicitly enables both its `workers.dev` route and
Preview URLs. This produces a reachable `howmuch-preview.<account>.workers.dev`
endpoint for end-to-end checks while production serves `https://howmuch.tk.sg`
(with `https://howmuch.soon.sg` redirecting to it).

## Authorized remote deployment

After verifying identity/resources, migrate before deploying **only the authorized environment**. Commands below run from `apps/worker`; a preview request does not authorize production.

Preview:

```sh
cd apps/worker
wrangler d1 migrations apply DB --remote --env preview --profile yj
bun run deploy:preview
wrangler d1 migrations apply DB --env tk --remote --profile tinkertanker
bun run deploy:tk
```

## Production: Tinkertanker (`howmuch.tk.sg`)

Production runs in the Tinkertanker Cloudflare account
(`b8b1032c61d9475cd00229c74db7ec72`, Wrangler profile `tinkertanker`) as
environment `tk` in `wrangler.jsonc`:

- Worker `howmuch` with D1 database `howmuch-production`
  (`df039dbc-6dda-4150-9dc3-5854a8ca6818`, APAC), custom domain
  `https://howmuch.tk.sg`, serving the web front-end and API on one hostname.
- One cron, `5 16 * * *` (00:05 Asia/Singapore), materialises due scheduled
  transactions; it catches up overdue occurrences (25 per run, idempotent via
  deterministic operation IDs). No YNAB configuration. Keep
  `HOWMUCH_API_TOKEN` as an encrypted secret on this Worker.
- Do not add `HOWMUCH_REDIRECT_TARGET` to the `tk` env; the redirect belongs to
  the legacy YJ env only, and setting it here would loop production onto itself.
- Deploy from `apps/worker` with `bun run deploy:tk`, which pins
  `--env tk --profile tinkertanker`. All asset requests run through the Worker
  (`run_worker_first: true`) so the redirect mode below applies to every path.
- Pushing a `v*` tag (e.g. `v1.0.0`) triggers an automatic production deploy
  via `.github/workflows/deploy.yml`, authenticated by the `CLOUDFLARE_API_TOKEN`
  repo secret and pinned to the Tinkertanker account ID. The workflow deploys
  only — it never applies D1 migrations. If a release includes a migration,
  apply it manually (`wrangler d1 migrations apply DB --env tk --remote
  --profile tinkertanker`) before tagging, following the verification order
  in this document.

## Legacy: YJ redirect (`howmuch.soon.sg`)

The former production Worker in the YJ account
(`810a0c404daff0737f4a2a97a7aab092`, profile `yj`) now redirects every
request — SPA routes, API paths, queries, POST bodies — to
`https://howmuch.tk.sg` with HTTP 308 via the `HOWMUCH_REDIRECT_TARGET` var.
The iOS app and any browser follow it transparently; only the API token secret
and the frozen database remain on that Worker. Its D1 database
`howmuch-production` (`57dc5569-d639-44c1-bb9d-6214f43a43b8`) is the final
2026-09-11 cutover snapshot, kept as a cold backup; never write to it. The
`soon.sg` zone and its Email Routing stay in the YJ account.

Rollback to the legacy stack: remove `HOWMUCH_REDIRECT_TARGET` from the
top-level vars in `wrangler.jsonc`, set `HOWMUCH_TRANSITION_READ_ONLY=false`,
deploy with `--profile yj`, and point clients back. Any writes made on the
Tinkertanker stack after cutover live only in its database.

## Restoring or bulk-loading D1 data

A plain `d1 export` dump cannot be re-imported in one shot: D1's import
endpoint enforces foreign keys per chunk, and a dump creates parent tables
(notably `payees`) long after child rows reference them. Import schema first,
then data per table in parent-first order, then triggers (they would otherwise
fire `RAISE(ABORT, ...)` guards during bulk load):

```sh
cd apps/worker
wrangler d1 export howmuch-production --env tk --remote --profile tinkertanker --output <local-file>.sql

# Build a local copy, then emit schema/data/triggers in dependency order:
sqlite3 local-copy.sqlite < <local-file>.sql
sqlite3 local-copy.sqlite "SELECT sql||';' FROM sqlite_master WHERE type='table' AND sql IS NOT NULL AND name!='sqlite_sequence' ORDER BY rowid" > 00_schema_tables.sql
sqlite3 local-copy.sqlite "SELECT sql||';' FROM sqlite_master WHERE type='index' AND sql IS NOT NULL ORDER BY rowid" >> 00_schema_tables.sql
sqlite3 local-copy.sqlite "SELECT sql||';' FROM sqlite_master WHERE type='trigger' ORDER BY rowid" > 99_triggers.sql
# Split INSERT lines from the dump into one file per table. Import order:
# d1_migrations, sqlite_sequence, plans, users, auth/password/session tables,
# plan_memberships, accounts, account_preferences, category_groups,
# categories, payees, transactions, subtransactions, source_events,
# import_sessions, import_rows, ynab_sync_state, sync_*, audit_events,
# write_commands (before write_state: write_state.last_command_id references
# it), write_state, write_assertions, ynab_raw_objects, scheduled_* tables,
# then 99_triggers.sql last.

wrangler d1 execute DB --env tk --remote --profile tinkertanker --file 00_schema_tables.sql -y
# ...then each data chunk in the order above, then:
wrangler d1 execute DB --env tk --remote --profile tinkertanker --file 99_triggers.sql -y
```

Re-importing into a non-empty database will conflict; drop the copied tables
(child-first) or recreate the database before a load. Keep SQL dumps, local
copies, and Time Travel bookmarks out of source control; `data/` is gitignored
for this purpose. Verify parity with counts only — never print transaction rows.

The deployment scripts build the web app immediately before Wrangler uploads
its assets. Use them rather than invoking `wrangler deploy` directly so `/docs`
and the rest of the SPA cannot be missing or stale.

Keep `HOWMUCH_API_TOKEN` as an encrypted secret. Use the local, validated import, parity, and D1-bootstrap tools in `docs/ynab-migration.md` for any YNAB work. They copy the verified ledger, provenance, and raw mirror into an otherwise clean target. Do not use an unverified SQLite file or ad-hoc table copy.

## Historical: temporary YNAB transition mode

> Completed. The YNAB transition finished before the 2026-09-11 account
> migration; production (Tinkertanker) runs no YNAB configuration, no cron,
> and accepts writes normally. This section is kept for reference and for its
> privacy-safe verification rules, which still apply to any operational work.

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
