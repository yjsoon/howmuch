# Deploy to Cloudflare button: local E2E

Revision: branch `claude/project-thread-s226ue` on top of `b381a99` (main after #293), before commit.
Environment: Linux container, wrangler 4.112.0, Bun 1.4.2. Synthetic data only; no Cloudflare account used.

## What was checked

1. Workers Builds uses Bun 1.2.15 by default. With Bun 1.2.15 installed from npm, `bun install` on a fresh clone left `bun.lock` unchanged and `bun run --cwd apps/web build` passed (typecheck and bundle).
2. `bun run deploy` outside Workers Builds exits 1 with "Refusing to deploy: this script runs only on Cloudflare Workers Builds".
3. `bunx wrangler deploy --dry-run --config wrangler.jsonc` from the root reads 105 asset files and lists bindings DB (D1 `halation`), ASSETS, HOWMUCH_DEFAULT_PLAN_ID, HOWMUCH_TIME_ZONE=UTC, HOWMUCH_TRANSITION_READ_ONLY=false.
4. Local run of the root config:
   - `printf 'HOWMUCH_API_TOKEN=e2e-setup-token-0123456789\n' > .dev.vars` (removed afterwards)
   - `bunx wrangler d1 migrations apply DB --local --persist-to $P --config wrangler.jsonc`: 0001 to 0018 applied.
   - `bunx wrangler dev --config wrangler.jsonc --persist-to $P --port 8799`
   - `GET /api/auth/status` → `setup_required: true, bootstrap_required: true`
   - `POST /api/auth/setup` with the bearer token, username `owner` → 200
   - `POST /api/auth/login` → 200, cookie session
   - `GET /v1/plans` → one plan, id `0d4f2c1e-6b8a-4e57-9a3c-5f1b7e2d9c40`
   - `GET /` → 200 (web app)
   - `POST /v1/plans/{id}/accounts` "E2E Card" → created
   - `POST /api/import/csv` with two identical rows (2026-10-01, Synthetic Cafe, 4.50) → `imported: 1, duplicate: 1, failed: 0`
   - `GET /v1/plans/{id}/transactions` → 1 transaction, Synthetic Cafe, -4500
   - `wrangler d1 execute DB --local ... "select count(*) n from transactions"` → n = 1 (persisted)
5. `bun test`: 880 pass, 0 fail.

## Not checked

- The live Deploy to Cloudflare flow (repository copy, D1 provisioning, secret prompt, Workers Builds run). It needs a Cloudflare account on the Workers Paid plan.
- The iOS change (empty default server): no Xcode on this machine, so it is uncompiled and untested in Simulator.
