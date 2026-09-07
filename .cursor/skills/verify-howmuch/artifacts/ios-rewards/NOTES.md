# ios-rewards proof

- Feature: `ios-rewards`
- Entry points used: none on Simulator. This Linux VM has no xcodebuild and no Simulator.
- Instance: `http://127.0.0.1:44237` (control-howmuch run `20260907T101249-6668`)
- Action: POST `/api/auth/setup` as `verifier`, POST `fixtures/rewards-tracker-export.json` to `/api/import/rewards-tracker`, then GET the report with `group=flag` and `group=payee`.
- API result: Travel Card miles tile data, qualifying spend `830.8`, Dining and Online flags, payee groups include Candlenut.
- Side effect: `report-flag.json` and `report-payee.json`.
- Not proved: tab bar, All Time chip, empty copy, pull to refresh. Drive `features/ios-rewards.md` on a Mac.
