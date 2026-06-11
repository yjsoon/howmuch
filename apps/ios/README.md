# HowMuch iOS

A YNAB-styled transaction ledger and reports companion (modelled on YNAB's iOS app, minus the Plan tab and all envelope-budgeting workflows).

API dependency:

- `GET/POST/PUT/DELETE /v1/plans/{id}/transactions[/{txid}]`
- `GET /v1/plans/{id}/accounts`, `/categories`, `/payees`, `/settings`
- `GET /api/reports/spending-breakdown`
- `GET /api/reports/income-vs-spending`
- `GET /api/reports/net-worth`
- `GET /api/reports/age-of-money`

The app stays transaction-led: accounts, registers, capture, and reflection. It does not expose envelope budgeting or YNAB credit-card payment workflows.

## App Structure

`apps/ios/HowMuch.xcodeproj` contains a SwiftUI app (iOS 26+) with a Liquid Glass tab bar — Accounts | Categories | Reflect, with + Transaction floating separately at the trailing edge as a search-role tab that opens the capture sheet — plus a connection sheet:

- `Accounts`: grouped account list (Cash / Credit / Tracking / Closed) with collapsible sections, group totals, and an All Transactions row. Each account opens its register.
- `Register`: date-grouped transactions with working balance, search, uncleared and uncategorised filter banners, cleared/reconciled badges, flag bars, memo chips, and split/transfer labels. Tapping a row opens the edit form.
- `Categories`: YNAB's category list without the budget columns — a `‹ June 2026 ›` month stepper, the month's total spending, collapsible groups with totals, and per-category spend (zero-spend categories included). Rows drill into that category's transactions for the month; bookkeeping groups sit behind a toggle.
- `Transaction` (centre + button): YNAB-style capture sheet. An Outflow/Inflow segmented pill owns the sign (the header turns lime for inflows), the amount is driven by a calculator keypad (digits, `+`, `−`, `=`, backspace, clear, done), and payee/category/account/date push pickers. Picking a payee pre-fills the category it was last used with. Cleared toggle, flag, and memo live in a second card. Editing adds Delete Transaction.
- `Reflect`: cards for Spending Breakdown (stacked share bar, top categories), Net Worth (assets/debts, column trend), Income vs Spending (paired columns), and Age of Money. Each card opens a detail screen; Spending Breakdown and the trends support Month (`‹ June 2026 ›` stepper) and Preset (This Month … Year to Date) ranges, and category rows drill into a filtered register. Age of Money always measures the full history, since the server replays income lots from `from`.
- `Connection` (ellipsis on either tab): base URL, bearer token, and plan ID persisted in `UserDefaults`, with a test-connection check against `GET /v1/user`.

Visual language follows YNAB: warm cream canvas, white rounded cards, blurple accent, lime inflow highlight, ledger red/green amounts, monospaced digits. Chrome follows iOS 26 Liquid Glass: native glass tab and navigation bars (the tab bar minimises on scroll), a glass keypad panel, a glass-prominent Save pill, and a glass toast — content cards stay opaque per the glass guidelines.

State lives in one observable `AppModel` with independent load phases per surface (reference data, ledger, reports), so a failure in one tab does not bleed into the others. Dates use the local calendar (a transaction entered before 8am SGT must not land on yesterday's GMT date). Bookkeeping category groups from the YNAB import ("Hidden Categories", "Non-Personal", inflows) are demoted in pickers and reports via the same quiet-group heuristic as the web app. The last-used account is remembered across launches.

## Validation

Build from the repo root:

```sh
xcodebuild -project apps/ios/HowMuch.xcodeproj -scheme HowMuch -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/howmuch-derived CODE_SIGNING_ALLOWED=NO CLANG_MODULE_CACHE_PATH=/tmp/howmuch-module-cache SWIFT_MODULECACHE_PATH=/tmp/howmuch-module-cache build
```
