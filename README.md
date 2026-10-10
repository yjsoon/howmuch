# Halation

Halation is a personal ledger built around credit card rewards. You record transactions, tag them with categories and flags, and Halation shows how each card is earning: how far you are from its minimum spend, how much headroom is left before its cap, and what you have earned in miles or cashback this period. It also reports on spending, income and net worth. There is no budgeting: categories describe spending rather than ration it.

It has four parts:

- **Card rewards tracking.** Each card's rules live alongside the ledger: cashback or miles rates, flag-based bonus categories, minimum and maximum spend, spending tiers, earning blocks, and billing, calendar, promotional or repeating reward periods. The Rewards board shows every card in its own current period, and you can look back to any past date or range. Halation uses the same calculation rules as [Rewards Tracker for YNAB](https://github.com/yjsoon/ynab-rewards-tracker), so you can import its settings or exchange one card's configuration at a time. An optional tool drafts reward rules from a bank's terms using your own AI provider key, for you to review before saving. See [rewards](docs/rewards.md).
- **A ledger with a YNAB-compatible API.** The `/v1` endpoints follow YNAB's API shapes for plans, accounts, categories, payees, transactions and scheduled transactions, so tools written for YNAB can talk to Halation. Native `/api` endpoints add reports and imports. Every instance serves its API documentation at `/docs`; the source is [the API contract](docs/api-contract.md).
- **A native iPhone app.** A SwiftUI app with account registers, quick capture from text, photos and the share sheet, scheduled transactions, reconciliation, the Rewards board and the Reflect reports. It can keep the ledger on the phone or connect to your own Halation server, and it queues new transactions offline when the connection drops.
- **Straightforward CSV import.** Send rows of date, payee, memo, outflow and inflow to `POST /api/import/csv` and Halation adds them to an account, skipping duplicates and recording each row's outcome. The web app's statement formatter turns statement images into those rows using your own AI provider key, and YNAB users can bring their history across from the YNAB API or a YNAB web export.

Halation also runs in the browser, with the same register, Rewards board and reports as the iPhone app.

## Getting started

Halation is self-hosted only. There is no hosted service and no public sign-up: your ledger lives on your phone or in your own Cloudflare account. Optional AI features, such as the statement formatter, reward terms drafting and category suggestions, send the content you choose to the AI provider you configure, and that provider's retention policies apply.

You have two options:

- **On your iPhone alone.** Choose **Start on this iPhone** when the app first opens and the ledger lives on the device.
- **On your own Cloudflare account.** Follow the [self-hosting guide](docs/self-hosting.md) to run the web app and API as a Cloudflare Worker with a D1 database. One instance serves one person or household, and the iPhone app can connect to it.

Moving from YNAB? The [YNAB migration guide](docs/ynab-migration.md) covers both import routes: `bun run import:ynab` for the API and `bun run import:ynab-export` for a web export.

## Development

Local development uses Bun and SQLite. The Bun server is for local development only and is not a supported way to self-host.

```sh
bun install
bun run demo:seed
bun run dev:stack
bun test
```

The local API binds `127.0.0.1` by default. To serve beyond the machine, set `HOWMUCH_HOST` (for example `0.0.0.0`) together with `HOWMUCH_API_TOKEN`. The server refuses to start on a non-loopback host without a token, and anything tunnelling or reverse-proxying to the loopback server needs the token too.

For a checked web build, run `bun run --cwd apps/web build`. It runs TypeScript checking and Vite bundling concurrently and fails if either fails. Use `typecheck` in that package for checking alone; `bundle` alone is not a validation gate. Worker builds and deployments wait for the checked web build.

For iOS builds, use `scripts/ios-xcodebuild.sh` and keep its project-local DerivedData cache; see the [iOS app guide](apps/ios/README.md) and [iOS validation guidance](apps/ios/AGENTS.md). Compare like-for-like actions when measuring incremental builds: switching between `build` and `build-for-testing` can change the products Xcode needs to prepare.

The repository is laid out as follows:

- `apps/api`: the ledger, reports and importers.
- `apps/web`: the browser app.
- `apps/worker`: the Cloudflare Worker that serves the web app and API from D1.
- `apps/ios`: the iPhone app, which bundles `apps/api` to run the ledger on the device.
- `docs`: the [API contract](docs/api-contract.md), [architecture](docs/architecture.md) and [deployment](docs/deployment.md) notes.

### Hosting and authentication

The hosted runtime is a Cloudflare Worker using production and preview D1 databases. The browser uses username/password login with an `HttpOnly` session cookie; iOS stores an opaque session token in Keychain. The static bearer token remains available for one-time account setup and default-plan integrations, and personal API tokens can be minted in the web app.

Production is a one-time YNAB cutover: the imported source mirror is lossless and read-only, while Halation-owned category assignments, targets and scheduled-transaction changes are stored separately. No recurring YNAB sync is configured. A Halation-only production cron enters due schedules daily at 00:05 Asia/Singapore; preview has no cron. See [deployment](docs/deployment.md).

### Naming

The product name is Halation; `howmuch` remains its compatibility identity. Keep the existing URLs, iOS bundle ID `sg.soon.howmuch`, signing team, app group, `howmuch://` links, storage keys and paths, API formats and infrastructure names unchanged. These preserve installed apps, saved data, credentials and integrations. The repository, packages and Xcode project and scheme also keep their existing names; do not globally replace them when updating branding.

## Licence

Halation is MIT-licensed. See [LICENSE](LICENSE).

Halation is not affiliated with or endorsed by YNAB.

The bundled web fonts (IBM Plex Sans, IBM Plex Mono and Newsreader, via `@fontsource`) are licensed under the SIL Open Font License 1.1.
