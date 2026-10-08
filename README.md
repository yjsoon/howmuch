# Halation

Halation (formerly HowMuch) is a personal ledger and reporting app with YNAB-compatible `/v1` APIs and native `/api` reports/imports.

The product name is Halation; `howmuch` remains its compatibility identity. Keep the existing URLs, iOS bundle ID `sg.soon.howmuch`, signing team, app group, `howmuch://` links, storage keys/paths, API formats and infrastructure names unchanged. These preserve installed apps, saved data, credentials and integrations. The repository, packages and Xcode project/scheme also retain their existing names; do not globally replace them when updating branding.

To run your own instance on Cloudflare, see [self-hosting](docs/self-hosting.md).

Public API documentation is available at [howmuch.tk.sg/docs](https://howmuch.tk.sg/docs). Its source is [the API contract](docs/api-contract.md).

Local development uses Bun and SQLite. The Bun server is for local development only and is not a supported way to self-host:

```sh
bun run demo:seed
bun run dev:stack
bun test
```

The local API binds `127.0.0.1` by default. To serve beyond the machine, set
`HOWMUCH_HOST` (for example `0.0.0.0`) together with `HOWMUCH_API_TOKEN`; the
server refuses to start on a non-loopback host without a token, and anything
tunnelling or reverse-proxying to the loopback server needs the token too.

For a checked web build, run `bun run --cwd apps/web build`. It runs TypeScript
checking and Vite bundling concurrently and fails if either fails. Use `typecheck`
in that package for checking alone; `bundle` alone is not a validation gate.
Worker builds and deployments continue to wait for the checked web build.

For iOS builds, use `scripts/ios-xcodebuild.sh` and retain its project-local
DerivedData cache; see [iOS validation guidance](apps/ios/AGENTS.md). Compare
like-for-like actions when measuring incremental builds: switching between
`build` and `build-for-testing` can change the products Xcode needs to prepare.

The hosted runtime is a Cloudflare Worker using production and preview D1 databases. The browser uses username/password login with an `HttpOnly` session cookie; iOS stores an opaque session token in Keychain. The static bearer token remains available for one-time account setup and default-plan integrations. Production is a one-time YNAB cutover: the imported source mirror is lossless and read-only, while Halation-owned category assignments, targets, and scheduled-transaction changes are stored separately. No recurring YNAB sync is configured. A Halation-only production cron enters due schedules daily at 00:05 Asia/Singapore; preview has no cron. See [deployment](docs/deployment.md).

YNAB API and export imports remain available through `import:ynab` and `import:ynab-export`.

The iOS register supports signed split allocations, including split transfers; duplicating a split for today creates fresh child lines rather than reusing the original IDs.

## Licence

Halation is MIT-licensed. See [LICENSE](LICENSE).

Halation is not affiliated with or endorsed by YNAB.

The bundled web fonts (IBM Plex Sans, IBM Plex Mono and Newsreader, via
`@fontsource`) are licensed under the SIL Open Font License 1.1.
