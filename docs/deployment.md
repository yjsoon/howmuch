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

For a first remote deployment, migrate before deploying:

```sh
cd apps/worker
wrangler d1 migrations apply DB --remote --env preview
wrangler deploy --env preview
wrangler d1 migrations apply DB --remote
wrangler deploy
```

Keep `HOWMUCH_API_TOKEN` and optional `HOWMUCH_YNAB_TOKEN` as encrypted secrets. Do not copy a legacy SQLite database into D1; this is a clean-slate bootstrap.

After the password-auth migration and Worker are deployed, open the app on its HTTPS custom domain. When no user exists, the setup form requests:

- a username containing 3–64 letters, numbers, dots, underscores, or hyphens;
- a password of at least 15 characters;
- the existing `HOWMUCH_API_TOKEN` as a one-time bootstrap token.

Setup atomically creates the first owner and is permanently disabled once a user exists. Do not put the username or password in deployment commands, source control, or chat. The static API token continues to authorize automation against only `HOWMUCH_DEFAULT_PLAN_ID`.
