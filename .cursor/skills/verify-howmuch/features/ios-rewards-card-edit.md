# iOS Rewards card edit

Rewards cards are stored on the plan and edited on the Rewards tab. **Add card** opens a new-card editor. A tile opens that card. The board hides a card whose calculation reports that maximum spend is exceeded. The editor still opens that card by id from Rewards import stored cards.

## Sub-features

- `ios-rewards-add-card` shows **Add card** on the empty tab and the filled board, and opens the Add card editor.
- `ios-rewards-create` saves a native card mapped to **Travel Card** and returns to Rewards.
- `ios-rewards-edit-delete` loads a stored card from a tile, then **Delete card** after the confirm.
- `ios-rewards-capped-hidden` hides a capped tile on the board and still opens the same card from Rewards import → Travel Card.

## How to get to it (user POV)

- Choose **Rewards**, then **Add card**.
- Choose a tile on Rewards.
- After a tile is hidden, choose **More → Connection settings → Rewards import**, then the stored card name.

## Driving it with control-howmuch

Preconditions:

- `control-howmuch doctor` passes.
- [iOS connection](./ios-connection.md) signed in as `verifier` against this stack.
- Demo ledger still contains Travel Card.
- Stay on **All Time**. Demo spends are 2026-03-01 through 2026-05-24.
- Xcode Simulator is running HowMuch (`sg.soon.howmuch`). If Simulator is missing, skip this whole file.

- **Open empty.** Choose tab `Rewards`. Navigation title `Rewards`. **Add card** is present. Status mentions Rewards import and **Add card**. **Rewards import** stays on the empty panel.
- **Open editor.** Choose **Add card**. Sheet title `Add card`. Trailing `Save`. Fields include `Name`, `Issuer`, `Type`, `HowMuch account`.
- **Create.** Name `Verify cashback`. Issuer `UOB`. Type `Cashback`. HowMuch account `Travel Card`. Featured stays on. Earning rate `1`. Choose `Save`. Rewards lists a Cashback tile named `Verify cashback`.
- **Edit.** Choose the `Verify cashback` tile. Title is `Edit card`. HowMuch account is `Travel Card`. The account ledger lists Travel Card rows. Choose `Delete card`. Confirm heading is `Delete this reward card?`. Choose `Delete card`. Rewards no longer lists `Verify cashback`.
- **Lane 5.** Import `fixtures/rewards-tracker-export.json` from Rewards import if Travel Card is not already stored. Open the `Travel Card` tile. Set Maximum spend to `1`. Choose `Save`. The Rewards board omits the Travel Card tile. Open Rewards import and choose stored `Travel Card`. The editor still opens with title `Edit card` and account `Travel Card`.
- **HTTP match.** After create, `control-howmuch http GET /api/import/rewards-tracker?plan_id=local-plan` includes a card named `Verify cashback` with `ynabAccountId` `acct-credit`. Do not POST the card from `control-howmuch http` and call the tab verified.
- **Proof.** Screenshot empty Rewards with **Add card** (`artifacts/ios-rewards-card-edit/empty.png`), the Add card editor (`artifacts/ios-rewards-card-edit/new.png`), the board after create (`artifacts/ios-rewards-card-edit/created.png`), the board after the capped save (`artifacts/ios-rewards-card-edit/capped-hidden.png`), and the editor still open for Travel Card (`artifacts/ios-rewards-card-edit/capped-editor.png`).
- **Save-to-tile clock.** Darwin only. Budget 800 ms median over three samples. Time from the Save tap until the Rewards board shows the `Verify cashback` tile. Do **not** use `axe describe-ui` as t0 or as the wait; that call is about 1.6 s and is not the product clock. Fill Add card first. Then run `apps/ios/scripts/rewards-save-to-tile-clock.sh`:
  1. `DIR=$(apps/ios/scripts/rewards-save-to-tile-clock.sh begin)` then tap Save immediately (`cliclick` or a single `axe tap`, not a dump).
  2. `apps/ios/scripts/rewards-save-to-tile-clock.sh capture "$DIR"` polls `xcrun simctl io booted screenshot` every ~70 ms. `score` OCRs those frames afterwards and prints the first elapsed ms whose pixels show `Verify cashback` on Rewards.
  3. Repeat twice more (delete the card or use a distinct name, then create again). Write all three ms values and the median into `artifacts/ios-rewards-card-edit/NOTES.md`. Median over 800 ms fails.
- **Review video.** Darwin only. `xcrun simctl io booted recordVideo /tmp/rewards-ios-manage-review.mp4`, then 30–60 s of add, edit flags, delete. Stop the recorder. Keep stills at `/tmp/rewards-ios-manage-review-add.png` and `/tmp/rewards-ios-manage-review-flags.png`.

## Gotchas

- Empty state is only when the rewards report returns no cards. An all-capped board still has stored cards, so the empty panel stays away.
- **Add card** is the control on the empty panel and on the filled board. Both open a new card.
- Flag colour on a subcategory includes Unflagged. The ledger picker is None plus the six colours. None sends `null`.
- Linux CI cannot run Simulator. Native `RewardCardEditorTests` plus `control-howmuch http` are the proof this VM can produce. The 800 ms save-to-tile median and the review video are Darwin-only; an `axe describe-ui` dump after Save is not that median.
- Do not mark this recipe verified from web `/rewards/new`.
