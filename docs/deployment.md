# Deployment

This is the owner's runbook. To run your own instance, see [self-hosting](self-hosting.md).

The D1 databases (placement is per-database and fixed at creation):

- Production (Tinkertanker account, env `tk`): `howmuch-production-sg` = `d13295f9-10d4-4ac0-bf62-b3e8c78cbf29` — primary in **SIN** since the 2026-09-12 #183 cutover
- Frozen rollback snapshot (Tinkertanker account): `howmuch-production` = `df039dbc-6dda-4150-9dc3-5854a8ca6818` (KIX) — the pre-cutover state; never migrate against or write to it. Rollback is: point the `tk` env back at it and `deploy:tk`
- Legacy frozen backup (YJ account, top-level env): `howmuch-production` = `57dc5569-d639-44c1-bb9d-6214f43a43b8` (SIN) — never migrate against or write to it
- Preview (YJ account, env `preview`): `howmuch-preview` = `7ca818bd-7f04-4b9b-8a84-8c8f84a6a272`

Creating a D1 database that should live in Singapore: **do not pass a location
hint**. A no-hint primary is placed near where the create request originates,
so create from a machine in Singapore (never CI) and verify `served_by_colo` is
`SIN` on a `SELECT 1` before importing anything; delete and re-create until it
is. The `apac` hint is not Singapore-seeking — it resolves non-deterministically
to Japan/Korea, which is how production landed at KIX.

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

- Worker `howmuch` with D1 database `howmuch-production-sg`
  (`d13295f9-10d4-4ac0-bf62-b3e8c78cbf29`, primary in SIN since the 2026-09-12
  #183 cutover), custom domain
  `https://howmuch.tk.sg`, serving the web front-end and API on one hostname.
- One cron, `5 16 * * *` (00:05 Asia/Singapore), materialises due scheduled
  transactions; it catches up overdue occurrences (25 per run, idempotent via
  deterministic operation IDs). No YNAB configuration. A cron equal to the YNAB
  sync cron (`HOWMUCH_YNAB_SYNC_CRON`, default `10 16 * * *`) runs the YNAB
  sync only when that variable is set, a YNAB token or plan ID is configured,
  or transition read-only mode is on; otherwise it materialises. Keep
  `HOWMUCH_API_TOKEN` as an encrypted secret on this Worker.
- Optional: `TYPESAFE_API_KEY` (encrypted secret) turns on Jev category
  suggestions (`POST /api/tools/categorise`); without it the route returns 503.
  Set it from `apps/worker` with
  `bunx wrangler secret put TYPESAFE_API_KEY --env tk --profile tinkertanker`.
  `TYPESAFE_MODEL` (plain var) overrides the SDK default, `jev-latest`.
- Do not add `HOWMUCH_REDIRECT_TARGET` to the `tk` env; the redirect belongs to
  the legacy YJ env only, and setting it here would loop production onto itself.
- Deploy from `apps/worker` with `bun run deploy:tk`, which pins
  `--env tk --profile tinkertanker`. All asset requests run through the Worker
  (`run_worker_first: true`) so the redirect mode below applies to every path.
- Pushing a `v*` tag (e.g. `v1.0.0`) triggers an automatic production deploy
  via `.github/workflows/deploy.yml`, authenticated by the `CLOUDFLARE_API_TOKEN`
  repo secret and pinned to the Tinkertanker account ID. The workflow never
  applies D1 migrations. If a release includes a migration, apply it manually
  (`wrangler d1 migrations apply DB --env tk --remote --profile tinkertanker`)
  before tagging, following the verification order in this document.
- Migration `0019_own_imported_ynab_schedules.sql` copies every mirrored YNAB
  schedule into HowMuch's own schedule tables and adds `plans.ynab_sourced`. It
  must be applied **before** the Worker that reads them is deployed (the new
  code needs the column; the old code keeps working against the new schema).
  Run `scripts/backup-d1.sh` first. The migration is atomic and fails, changing
  nothing, if a mirrored schedule cannot be copied. Afterwards, with
  `wrangler d1 execute DB --env tk --remote --profile tinkertanker --command`,
  check that the two counts match and that the plan is marked:
  `SELECT (SELECT count(*) FROM ynab_raw_objects WHERE object_type='scheduled_transaction') AS mirrored, (SELECT count(*) FROM scheduled_transaction_edits WHERE origin='ynab-overlay') AS owned, (SELECT group_concat(ynab_sourced) FROM plans) AS plan_marked`.
  It leaves `ynab_raw_objects` untouched; pruning it is a separate decision (#161).
  Before applying, run this read-only preflight; every count must be 0, because
  a schedule the migration cannot copy makes it abort (atomically, so nothing
  is lost, but the release stalls):
  `SELECT (SELECT count(*) FROM ynab_raw_objects r WHERE r.object_type='scheduled_transaction' AND (json_extract(r.payload_json,'$.account_id') IS NULL OR json_extract(r.payload_json,'$.date_first') IS NULL OR json_extract(r.payload_json,'$.date_next') IS NULL OR json_extract(r.payload_json,'$.frequency') IS NULL OR json_extract(r.payload_json,'$.amount') IS NULL OR NOT EXISTS (SELECT 1 FROM accounts a WHERE a.id=json_extract(r.payload_json,'$.account_id')))) AS bad_schedules, (SELECT count(*) FROM ynab_raw_objects s WHERE s.object_type='scheduled_subtransaction' AND COALESCE(json_extract(s.payload_json,'$.deleted'),0)=0 AND (json_extract(s.payload_json,'$.amount') IS NULL OR json_extract(s.payload_json,'$.scheduled_transaction_id') IS NULL)) AS bad_lines`.
  Do not run a YNAB import between applying the migration and deploying the
  Worker: the old Worker would write a new schedule only to the mirror, where
  the new code does not look. Production has no YNAB configuration, so this
  only matters if one is added.
  Once a schedule is owned, a later YNAB import does not change or delete it.
- Before building or deploying, the workflow runs
  `scripts/check-d1-migrations.sh --env tk --remote`. It reads the
  `d1_migrations` table with a single `SELECT` and fails the run, without
  deploying, when any `*.sql` file in `apps/api/d1-migrations` is not recorded
  there. It also fails when it cannot read D1 at all. This step uses the separate
  `CLOUDFLARE_D1_READ_TOKEN` secret with only Account > D1 > Read, mapped to
  Wrangler's `CLOUDFLARE_API_TOKEN` environment variable for that step only
  (see [CI migration-check token](#ci-migration-check-token)). It uses a
  plain query rather than
  `wrangler d1 migrations list` because that command exits 0 even when
  migrations are pending and first runs a `CREATE TABLE IF NOT EXISTS` against
  the database. To check before tagging, run the same script from the repo
  root with `--env tk --remote --profile tinkertanker`; it is read-only.

### CI migration-check token

**Required before the next deploy:** an owner must create and store the separate
`CLOUDFLARE_D1_READ_TOKEN` repository secret. Do not broaden the deploy token.
The check fails closed if this secret is missing, expired, invalid, or lacks D1
Read; it never falls back to the deployment credential.

1. In the **Tinkertanker** Cloudflare dashboard, create an account API token
   named `howmuch-d1-read (GitHub Actions)` with **only Account > D1 > Read**.
   Scope it to Tinkertanker (`b8b1032c61d9475cd00229c74db7ec72`), not all accounts
   or YJ. Do not grant D1 Edit or any Workers permissions.
2. In `yjsoon/howmuch`, open Settings > Secrets and variables > Actions >
   New repository secret, name it **`CLOUDFLARE_D1_READ_TOKEN`**, and paste the
   token value. Alternatively, run
   `gh secret set CLOUDFLARE_D1_READ_TOKEN --repo yjsoon/howmuch` and paste it
   at the private prompt. Leave `CLOUDFLARE_API_TOKEN` unchanged.
3. Verify access read-only from the repo root in a Bash subshell, without
   putting the value in shell history (paste the **D1 Read** token at the prompt):

   ```bash
   (
     read -rsp 'D1 Read token: ' CLOUDFLARE_API_TOKEN; printf '\n'
     export CLOUDFLARE_API_TOKEN
     export CLOUDFLARE_ACCOUNT_ID=b8b1032c61d9475cd00229c74db7ec72
     scripts/check-d1-migrations.sh --env tk --remote
   )
   ```

   Expect `D1 migrations up to date: ... applied, none pending.` If migrations
   are pending, apply them separately using the authorized migration procedure
   before releasing; do not grant this token write access to bypass the check.
4. On the next **authorized** release, confirm the check, deploy, and `/health`
   steps pass. Re-running Deploy or pushing a `v*` tag deploys production;
   neither is needed merely to create or verify this secret.

Cloudflare shows the token value once. Keep it only in the repository secret
and private local input, never in source control, issues, PRs, logs, or chat.
Rotate it independently by creating a replacement with the same D1 Read-only
permission, updating `CLOUDFLARE_D1_READ_TOKEN`, verifying read access, then
revoking the old token. The expiry/exposure policy below applies to both tokens.

### CI deploy token

The `CLOUDFLARE_API_TOKEN` repository secret is a Tinkertanker **account** API
token named `howmuch-deploy (GitHub Actions)`. Because it is account-scoped it
cannot act on the YJ account, and the workflow also pins
`CLOUDFLARE_ACCOUNT_ID` to Tinkertanker (`b8b1032c61d9475cd00229c74db7ec72`)
as a second guard. The current token was created with no expiry.

- Permissions: the Workers permission set that `wrangler deploy` needs (the
  "Edit Cloudflare Workers" style set it was created with). Do not add D1 Read
  for the pending-migrations check; that step uses its own token. The workflow
  never writes to D1, so D1 Edit is not required.
- Where it lives: only in the `yjsoon/howmuch` repository secrets (Settings >
  Secrets and variables > Actions) and in the Tinkertanker account's API token
  list. Cloudflare shows the value once at creation; never write it into the
  repo, an issue, a PR, a log, or chat.

Rotation is an owner action, because step 3 deploys production:

1. In the Tinkertanker dashboard, create a replacement account API token with
   the same deployment permissions and the expiry set by the policy
   below. Keep it scoped to the Tinkertanker account.
2. Store it without putting it on the command line: run
   `gh secret set CLOUDFLARE_API_TOKEN --repo yjsoon/howmuch` and paste the
   value at the prompt. Leave `CLOUDFLARE_D1_READ_TOKEN` unchanged; the migration
   check does not validate the replacement deploy token's permissions.
3. Run the Deploy workflow via `workflow_dispatch` (Actions > Deploy > Run
   workflow, or `gh workflow run deploy.yml --repo yjsoon/howmuch --ref main`)
   from a ref that is safe to ship, and confirm the migrations check, the
   deploy, and the `/health` step all pass.
4. Revoke the old token in the Tinkertanker dashboard, and confirm only the
   new `howmuch-deploy` token remains.

Recommended policy, pending owner confirmation:

- Give each new token a 12-month expiry and set a calendar reminder about a
  month before it lapses, then rotate with the steps above. An expired token
  only stops CI deploys; the running Worker is unaffected, and
  `bun run deploy:tk` still works through the `tinkertanker` profile.
- Rotate immediately on suspected exposure (for example the value appearing
  in a log or chat, or a compromised workflow dependency) and when a
  maintainer with access to the repository secrets or the Tinkertanker account
  leaves.

### Smart Placement experiment (#172, reverted)

The `tk` env's `wrangler.jsonc` briefly set `"placement": { "mode": "smart" }`
as a reversible experiment, enabled 2026-09-12 while the D1 primary
(`howmuch-production`) still ran at KIX and the Worker ran at SIN, so each
of the several sequential D1 calls per request paid a cross-region hop.

After the D1 move to Singapore (#183), the experiment became
counterproductive: Smart Placement had pinned the Worker at KIX next to
where the database used to be, so requests now went SIN client → KIX
Worker → SIN database instead of staying local. Measured from Singapore,
`/health` returned in ~145 ms with response headers `cf-placement:
remote-KIX` and `cf-ray: …-SIN`, confirming the pin. With both the database
and users in Singapore, default edge placement is strictly better, so the
`placement` stanza was removed from `env.tk` and default placement restored.

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

From `apps/worker`, deploy this top-level Worker with
`bun run deploy:yj-redirect`. That script pins `--profile yj` and does not
take an `--env`, so Wrangler uses the top-level redirect configuration.
`bun run deploy` exits with an error and does not upload.

To roll the live hostname back to this Worker, remove
`HOWMUCH_REDIRECT_TARGET` from the top-level vars in `wrangler.jsonc`.
Set `HOWMUCH_TRANSITION_READ_ONLY=false`.
From `apps/worker`, run `bun run deploy:yj-redirect`.
Then point clients back. Any writes made on the Tinkertanker stack after
cutover live only in its database.

## Backing up production D1

Recovery options are D1 Time Travel (~30 days, in-place) and the frozen
2026-09-11 cutover snapshot in the YJ account. Neither is a periodic export, so
run the backup routine from the repo root:

```sh
scripts/backup-d1.sh
# or, equivalently:
bun run backup:d1
```

- Destination: gitignored `data/backups/` (override with `HOWMUCH_BACKUP_DIR`).
  Each run writes `howmuch-production-YYYY-MM-DD.sql` (UTC date) and
  `howmuch-production-YYYY-MM-DD.sql.sha256`, and appends diagnostics to
  `data/backups/.backup-d1.log`.
- The script is read-only against production. It first verifies that Wrangler
  profile `tinkertanker` exposes `howmuch-production-sg` = `d13295f9-...`, then
  exports with `wrangler d1 export howmuch-production-sg --env tk --remote
  --profile tinkertanker`. It loads the dump into a throwaway local sqlite copy
  and compares count-only statistics with the live database: the application
  table count must match exactly and a small non-sensitive set of row counts
  must match within a tolerance. It never prints rows, payees, memos, or
  amounts. Validation failure exits non-zero before publishing, so a failed run
  leaves the previous archive untouched.
- Cadence: **monthly at minimum**, and always before a D1 migration or other
  risky change. The YNAB raw mirror dominates the ~204 MB dump.
- Retention: keeps the newest archive from each of the most recent 6 calendar
  months (`HOWMUCH_BACKUP_RETENTION_MONTHS`). Pruning removes only
  `howmuch-production-*.sql` and its `.sha256` inside the configured backup
  directory; it never touches `data/tk-migration/` or other artefacts, and the
  newest dump is always kept.
- Other overrides: `HOWMUCH_BACKUP_COUNT_TOLERANCE`, `HOWMUCH_BACKUP_MIN_BYTES`,
  `HOWMUCH_BACKUP_EXPECTED_BYTES`, `HOWMUCH_BACKUP_MAX_BYTES`.
- The dump is a complete, unencrypted ledger and stays on local disk only. Do
  not commit it and do not upload it to GitHub (the repository is public) or
  any other world-readable location. Copying it to a private off-machine store
  (for example a private R2 bucket) is a separate owner decision; the script
  deliberately creates no Cloudflare resources and implements no scheduling.
- Restore is **not** a single command: use the chunked procedure below and
  budget roughly 30 minutes. Time Travel is the fast in-place option; this
  export is the independent copy that survives database or account loss.

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
