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
wrangler deploy --env preview
wrangler d1 migrations apply DB --remote
wrangler deploy
```

Keep `HOWMUCH_API_TOKEN` as an encrypted secret. Post-cutover Worker configuration deliberately has no YNAB token, plan, or similarity variables and never schedules a YNAB sync; future deployments must not re-enable them. Production sets `HOWMUCH_TIME_ZONE=Asia/Singapore` and runs the HowMuch-only scheduled-entry catch-up at `5 16 * * *` (`00:05` Singapore time). Preview carries the same timezone but keeps `triggers.crons` empty. The cron path is separate from the owner bulk endpoint: it enters at most 25 occurrences per run, takes one stable-order occurrence per due schedule per round, skips closed accounts, and isolates bad schedules. Its log contains only count-only occurrence, skip, failure, and remaining-work fields; deterministic occurrence receipts make retries and recovery after a partial run safe. A non-zero failure count is logged before the Worker marks the cron invocation failed for observability.

Use the local, validated import, parity, and D1-bootstrap tools in `docs/ynab-migration.md` for any YNAB work. They copy the verified ledger, provenance, and raw mirror into an otherwise clean target. Do not use an unverified SQLite file or ad-hoc table copy. After cutover, do not run a YNAB re-import over a ledger with local writes such as account reconciliations; it would replace normalised YNAB-derived transaction state.

After the password-auth migration and Worker are deployed, open the app on its HTTPS custom domain. When no user exists, the setup form requests:

- a username containing 3–64 letters, numbers, dots, underscores, or hyphens;
- a password of at least 15 characters;
- the existing `HOWMUCH_API_TOKEN` as a one-time bootstrap token.

Setup atomically creates the first owner and is permanently disabled once a user exists. Do not put the username or password in deployment commands, source control, or chat. The static API token continues to authorize automation against only `HOWMUCH_DEFAULT_PLAN_ID`.
