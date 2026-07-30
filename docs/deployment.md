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
