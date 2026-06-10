# HowMuch iOS

The first iOS scope is a quick-entry fallback and lightweight report companion.

Initial API dependency:

- `POST /api/mobile/quick-entry`
- `GET /api/reports/spending-breakdown`
- `GET /api/reports/income-vs-spending`
- `GET /api/reports/net-worth`
- `GET /api/reports/age-of-money`

The app should stay transaction-led: choose account, amount, payee, category, memo, and optional flag. It should not expose envelope budgeting or YNAB credit-card payment workflows.

## App Structure

`apps/ios/HowMuch.xcodeproj` contains a SwiftUI app (iOS 17+) with three tabs and a connection sheet:

- `Capture`: amount-first quick entry. A Spent/Received toggle owns the sign (no typed minus signs), the amount uses the decimal pad, and the save button echoes the parsed amount. Saves confirm with a transient toast and haptic, then reset for the next entry while keeping account and category.
- `Recents`: latest 50 transactions grouped by day with per-day totals, ledger-coloured amounts, flag dots, and an Uncleared badge. Loading, failure (with retry), and empty states are distinct.
- `Reports`: compact cards for spending breakdown (share bars), income v spending (paired mini columns), net worth (sparkline plus delta), and age of money. Window (1M/3M/12M/YTD) and interval (week/month/year) controls refetch on change.
- `Connection` (gear icon): base URL, bearer token, and plan ID persisted in `UserDefaults`, with a test-connection check against `GET /v1/user`.

Visual language follows the web app's editorial-ledger palette: ledger red for outflows, racing green for inflows, monospaced digits for figures, serif report titles.

State lives in one observable `AppModel` with independent load phases per surface (reference data, recents, reports), so a failure in one tab does not bleed into the others.

## API Shape Notes

- The client models both `/api/mobile/quick-entry` and `/v1/plans/{id}/transactions`.
- The current capture flow posts to `/v1/plans/{id}/transactions` after client-side decimal-to-milliunit conversion so `cleared` survives end to end.
- Backend gap: `/api/mobile/quick-entry` still ignores `cleared` and `approved`, so it cannot yet back the full native capture form without losing state.

## Validation

Build from the repo root:

```sh
xcodebuild -project apps/ios/HowMuch.xcodeproj -scheme HowMuch -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/howmuch-derived CODE_SIGNING_ALLOWED=NO CLANG_MODULE_CACHE_PATH=/tmp/howmuch-module-cache SWIFT_MODULECACHE_PATH=/tmp/howmuch-module-cache build
```
