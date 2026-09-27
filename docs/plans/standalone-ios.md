# Standalone iOS (local-first) plan

Status: phase 1 done on `feat/standalone-ios` (2026-09-26). See [the handover](standalone-ios-handover.md).

## Goal

The App Store build of HowMuch works as a complete finance tracker with no server. A new user starts from scratch on the device. Connecting to a server is optional: it serves the owner and anyone who self-hosts this public repository. There is **no public registration** on `howmuch.tk.sg`, so the app offers no account creation and needs no account-deletion flow.

The owner's existing server-connected install must behave exactly as it does today.

## Decision: run the existing backend on the device

The iOS app is a thin client of the Worker API. The server computes balances, reports, rewards, schedules and reconciliation. Porting that to Swift would mean two engines to keep in step forever.

Instead, the app embeds the same TypeScript backend (`apps/api`) in JavaScriptCore, on top of an on-device SQLite database:

- `createHandler` is composed exactly as in `apps/worker/src/index.ts`: `D1Database`, `D1LedgerRepository`, `D1ReportService` and `D1AuthStore`.
- A small JS D1 binding wraps one synchronous Swift bridge, `__sqlite.exec(sql, paramsJson)`. `batch` is `BEGIN IMMEDIATE`/`COMMIT`, with `ROLLBACK` on error.
- The D1 migrations (`apps/api/d1-migrations`) apply unmodified. The device records the ones it has applied.
- In local mode, `APIClient` sends requests to the engine instead of `URLSession`. The views, models and HTTP contract are unchanged.

The spike (2026-09-25, macOS JavaScriptCore, JIT disabled to stand in for iOS) measured the bundle at 305 KB minified. It loaded in about 20 ms, warm reads took under 1 ms and a transaction write about 2 ms. No SQL specific to D1 turned up.

The engine needs these polyfills, bundled with the engine:

- `node:crypto`: SHA-256 in pure JS; `randomBytes` backed by `SecRandomCopyBytes`
- `crypto.randomUUID`
- URL, URLSearchParams, Headers, Request, Response, TextEncoder/Decoder, atob/btoa

The following do not work on the device, and the app hides them in local mode:

- password login (scrypt is stubbed)
- anything that needs `fetch` or streaming: the YNAB API import and the streaming reward tools

Constraints:

- One serial queue owns the JSContext and the SQLite handle, and never the main thread.
- The bundle must be rebuilt whenever `apps/api` changes. A check script fails when the committed bundle is stale.
- JS is bundled in the app, never downloaded, which keeps it within App Store rules.

## No budgeting

HowMuch has no budgeting. The app is Accounts, Rewards and Reflect, plus capture. Categories are tags on transactions, used by Reflect and the rewards rules. The iOS Plan tab (Ready to Assign, assigning money) was removed in this phase. The YNAB month overlays that remain in `apps/api` are legacy server code. Nothing ports or extends them.

A new local plan starts with a set of categories the user can edit. Native plans are plans with no YNAB `month` raw objects. Creating and editing categories and category groups is allowed only on native plans. A YNAB-mirror plan, such as the owner's production plan, returns 409, so its mirror stays untouched.

## Connecting a local install to a server

Snapshots use `GET /v1/plans/{id}/export_snapshot` and `POST /v1/plans/{id}/import_snapshot`, in the `howmuch-plan-snapshot` v1 format. IDs are generated on the client, and the import only accepts an empty plan.

The flow:

1. The user signs in with the existing login (the first owner is set up on the web, as today).
2. If the server plan is empty, the app exports the local snapshot, imports it to the server, then switches to server mode.
3. If the server plan has data, the user chooses:
   - **Use server data:** the local database is archived on the device and can still be exported.
   - **Keep local:** the app signs out of the server.
4. Ledgers are never merged, and a populated server plan is never overwritten.

Signing out of a server never deletes the archived local database.

## Phases

1. **Phase 1:** embedded engine and local mode; first-run choice between "Start on this iPhone" and "Connect to a server"; category management; snapshot export/import and the first-connect flow; schedules materialised on launch and on returning to the foreground in local mode.
2. **Phase 2:** make server mode local-first as well, so reads come from the device and writes queue for batched sync. This needs delta and tombstone reads for more than transactions, plus a command replay log. That is where the real user's data is at risk, so it is deliberately separate.
3. **Before App Store submission:**
   - move the associated domain from `webcredentials:howmuch.soon.sg` to `howmuch.tk.sg`
   - privacy policy URL and privacy manifest
   - profile on a device with a production-sized snapshot (JavaScriptCore without JIT)
   - review AI-provider key handling

## Known limits

- The D1 `write_state` is a global singleton, which serialises every plan on a shared server. That is fine for a handful of self-hosted users.
- The local engine runs one request at a time.
