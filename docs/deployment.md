# Deployment

Deployment is blocked. No remote preview or production D1 database exists or is bound.

The checked-in Wrangler configuration uses visibly local, ID-less `DB` entries for top-level and preview configuration. Environment bindings are repeated because Wrangler does not inherit them. Local work may apply the canonical migration with:

```sh
cd apps/worker
wrangler d1 migrations apply DB --local
bun run build
```

Before any deployment, create the intended D1 databases through a separately reviewed process, record and review their exact IDs, add `database_id` to both relevant entries, replace the failing deploy guards, apply `apps/api/d1-migrations/0001_initial.sql`, and run API/Worker integration checks. Keep `HOWMUCH_API_TOKEN` and optional `HOWMUCH_YNAB_TOKEN` as encrypted secrets. Do not copy a legacy SQLite database into D1; this is a clean-slate bootstrap.
