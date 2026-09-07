# ios-rewards-import proof

- Feature: `ios-rewards-import`
- Entry points used: none on Simulator. This Linux VM has no xcodebuild and no Simulator.
- Instance: `http://127.0.0.1:44237` (control-howmuch run `20260907T101249-6668`)
- Action: POST `fixtures/rewards-tracker-export.json` twice as `{ plan_id, payload }`.
- API result: first import `cards` 1, `tag_mappings` 2, `accounts_upserted` 1, `transactions_imported` 0. Replay keeps one Travel Card (`card-travel` / `acct-credit`).
- Side effect: `snapshot.json`.
- Not proved: Connection Tools link, file picker, invalid JSON copy. Drive `features/ios-rewards-import.md` on a Mac.
