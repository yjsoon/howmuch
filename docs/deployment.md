# HowMuch Deployment Runbook

This is the practical deployment path for the current Bun + SQLite HowMuch app.
The app is still a single-user, self-hosted service, so the deployment should
preserve the SQLite backup story and avoid a last-minute Worker/D1 rewrite.

## Recommendation

Use Cloudflare for the public edge, but do not port the API to Workers before
the morning demo.

The safest path is:

1. Run the Bun API on a small persistent host with a mounted SQLite volume.
2. Put Cloudflare in front of it with either a proxied DNS record or Cloudflare
   Tunnel.
3. Serve the Vite web build from the same public origin, or add a tiny edge
   proxy so `/api/*` and `/v1/*` stay same-origin for the web client.

Cloudflare Pages is a good fit for the static frontend, but only if `/api` and
`/v1` are proxied to the Bun API. The web client currently calls relative paths,
which is good for same-origin deployment but will not work from a plain Pages
site unless the API paths exist on that same host.

## Current Runtime Assumptions

- API runtime: Bun, using `Bun.serve` in `apps/api/src/server.ts`.
- Config source: `Bun.env` in `apps/api/src/config.ts`.
- Database: local SQLite via `bun:sqlite`, defaulting to
  `data/howmuch.sqlite`.
- Database setup: startup creates the parent directory, opens SQLite, enables
  foreign keys and WAL mode, then applies SQL files from `apps/api/migrations`.
- Auth: static bearer token through `HOWMUCH_API_TOKEN`; if unset, requests are
  allowed for local development.
- Web runtime: Vite/React static build from `apps/web`.
- Web API calls: relative `/api/*` and `/v1/*` fetches.

Production environment variables:

```sh
PORT=8787
HOWMUCH_DB_PATH=/var/lib/howmuch/howmuch.sqlite
HOWMUCH_API_TOKEN=replace-with-a-long-random-token
HOWMUCH_DEFAULT_PLAN_ID=local-plan
```

## Cloudflare Feasibility

### Cloudflare Pages

Verdict: good for the web frontend only.

Use these build settings if deploying the web app as a Pages project:

- Root directory: repository root
- Build command: `bun install --frozen-lockfile && cd apps/web && bun run build`
- Build output directory: `apps/web/dist`

Blocker for a full app: the API paths are relative. Pages needs a reverse proxy
for `/api/*` and `/v1/*`, or the API must be on the same origin by another
route.

### Cloudflare Workers

Verdict: not viable as a direct API deployment.

The current API imports `bun:sqlite` and uses Bun-specific server/config APIs.
Workers can enable many Node.js compatibility APIs, but this does not provide
`bun:sqlite` or a writable SQLite file at `data/howmuch.sqlite`.

### Cloudflare D1

Verdict: plausible future Cloudflare-native path, not an overnight drop-in.

The SQL schema is close to D1's SQLite model, but the repository layer expects
the synchronous `bun:sqlite` API:

- `db.query(...).get(...)`
- `db.query(...).all(...)`
- `db.query(...).run(...)`
- `db.transaction(...)`

D1's Worker binding API is asynchronous and binding-based, so this requires a
database adapter plus a broad async refactor through `LedgerRepository`,
`ReportService`, importers, route handlers, tests, and migrations.

### Cloudflare Containers

Verdict: technically aligned with the Bun runtime, but higher operational risk
than a normal VPS/container host for tomorrow.

Containers can run full-runtime applications with filesystem needs, but HowMuch
would still need container config, image publishing, routing, secret handling,
and a deliberate persistence/backup plan for SQLite. Use it after the demo if
we want to keep everything inside Cloudflare.

## Morning Ship Path

### Option A: Cloudflare Tunnel to a persistent host

Use this if a private machine or small VPS is available.

1. Build and validate:

   ```sh
   bun install --frozen-lockfile
   cd apps/web && bun run build && cd ../..
   bun test
   bun run smoke
   ```

2. Start the API on the host with a persistent database path:

   ```sh
   export PORT=8787
   export HOWMUCH_DB_PATH=/var/lib/howmuch/howmuch.sqlite
   export HOWMUCH_API_TOKEN="$(openssl rand -hex 32)"
   bun apps/api/src/server.ts
   ```

3. Serve `apps/web/dist` and reverse-proxy `/api/*` and `/v1/*` to
   `http://127.0.0.1:8787`.

4. Put Cloudflare Tunnel or a proxied Cloudflare DNS record in front of that
   single origin.

### Option B: Cloudflare Pages plus external API

Use this if Pages is required for the frontend.

1. Create a Pages project for `apps/web`.
2. Deploy the static web build.
3. Add a small proxy for `/api/*` and `/v1/*` to the Bun API origin before
   sharing the link.
4. Set `HOWMUCH_API_TOKEN` on the API and configure the iOS client with the same
   bearer token.

### Option C: Worker + D1 port

Use this only after the demo.

1. Introduce a database interface that supports async calls.
2. Port `LedgerRepository` and `ReportService` to that interface.
3. Add a Worker entrypoint that binds `env.DB` and uses Worker-compatible env
   vars/secrets.
4. Move migrations to Wrangler/D1 migrations.
5. Run the full API tests against both local SQLite and D1 local simulation.

## Read-Only Cloudflare Inspection

Wrangler is installed and usable on this machine. Read-only checks showed:

- Account: `YJ`
- Login: `cloudflare@yjsoon.com`
- Existing Pages projects: `yjsoon-blog`
- Existing D1 databases: none listed

Do not create Cloudflare resources from this worktree unless the final target
and naming are agreed.
