# iOS Rewards

Rewards is a tab. It shows imported Rewards Tracker cards against the HowMuch ledger. Envelope planning is **More → Plan**, not this tab. There is no live YNAB connection.

## Sub-features

- `ios-rewards-tab` opens Rewards from the tab bar. Navigation title is `Rewards`.
- `ios-rewards-empty` on a fresh verify instance, with no export imported, shows `No reward cards in this range.`, **Add card**, and a `Rewards import` button.
- `ios-rewards-import-then-view` after importing `fixtures/rewards-tracker-export.json` shows Travel Card on All Time.
- `ios-rewards-flags` lists Dining and Online flag rows on Travel Card.
- `ios-rewards-group` switches Group to Payee and lists Candlenut.

## How to get to it (user POV)

- Choose **Rewards** in the tab bar.
- From an empty Rewards screen, choose **Add card** or **Rewards import**, or open **More → Connection settings → Rewards import**.
- Plan and Assistant are not tabs. Choose **More**, then **Plan** or **Assistant**. Reflect is a tab.

## Driving it with control-howmuch

Preconditions:

- `control-howmuch doctor` passes.
- [iOS connection](./ios-connection.md) signed in as `verifier` against this stack.
- Demo ledger still contains Travel Card spends (Grab, Scoot, MUJI, Candlenut).
- Xcode Simulator is running HowMuch (`sg.soon.howmuch`). If Simulator is missing, skip this whole file.

- **Open empty.** Choose tab `Rewards`. Navigation title `Rewards`. Date range chip is `All Time`. Status is `No reward cards in this range.` Detail mentions Rewards import and **Add card**. Buttons `Add card` and `Rewards import` are present. Trailing ellipsis is `More`.
- **Import.** Choose `Rewards import`, or Connection settings → `Rewards import`. Choose `fixtures/rewards-tracker-export.json`. Choose `Import export`. Stored cards lists `Travel Card`.
- **Open filled.** Return to `Rewards` if needed. Pull to refresh. A Miles tile named `Travel Card` is visible. Qualifying spend is greater than `$0.00`. Group chip includes `Flag`, `Payee`, `Category`, `Memo`.
- **Group by payee.** Choose `Payee`. The groups table heading is `By Payee` and includes `Candlenut`.
- **HTTP match.** `control-howmuch http GET "/api/reports/rewards?plan_id=local-plan&group=payee"` returns `data.cards` with `card-travel` and `data.groups` containing Candlenut. Do not POST the import from `control-howmuch http` and call the tab verified.
- **Proof.** Screenshot the empty tab (`artifacts/ios-rewards/empty.png`), the Travel Card tile after import (`artifacts/ios-rewards/travel-card.png`), the payee groups table (`artifacts/ios-rewards/group-payee.png`), and save the GET JSON (`artifacts/ios-rewards/report.json`).

## Gotchas

- Demo rows are dated 2026-03-01 through 2026-05-24. `This Month` is empty unless today falls in that span. Stay on `All Time`.
- The tab reads the HowMuch ledger, not a second YNAB sync. Import the settings export first.
- Linux CI cannot run Simulator. Native `RewardsReportTests` plus `control-howmuch http` are the proof this VM can produce.
- Do not look for Rewards on Reflect. Reflect still has four report cards only.
