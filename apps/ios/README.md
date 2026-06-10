# HowMuch iOS

The first iOS scope is a quick-entry fallback and lightweight report companion.

Initial API dependency:

- `POST /api/mobile/quick-entry`
- `GET /api/reports/spending-breakdown`
- `GET /api/reports/income-vs-spending`
- `GET /api/reports/net-worth`
- `GET /api/reports/age-of-money`

The app should stay transaction-led: choose account, amount, payee, category, memo, and optional flag. It should not expose envelope budgeting or YNAB credit-card payment workflows.

## Scaffold

`apps/ios/HowMuch.xcodeproj` now contains a minimal SwiftUI app with:

- `Capture`: quick entry for account, date, payee, decimal amount, memo, category, flag colour, and cleared state.
- `Recents`: latest transactions from `/v1/plans/{id}/transactions`.
- `Reports`: compact summaries for spending breakdown, income vs spending, net worth, and age of money.
- `API Settings`: base URL, bearer token, and plan ID persisted in `UserDefaults`.

## API Shape Notes

- The client models both `/api/mobile/quick-entry` and `/v1/plans/{id}/transactions`.
- The current capture flow posts to `/v1/plans/{id}/transactions` after client-side decimal-to-milliunit conversion so `cleared` survives end to end.
- Backend gap: `/api/mobile/quick-entry` still ignores `cleared` and `approved`, so it cannot yet back the full native capture form without losing state.

## Validation

Build from the repo root:

```sh
xcodebuild -project apps/ios/HowMuch.xcodeproj -target HowMuch -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```
