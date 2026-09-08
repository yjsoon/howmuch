# Rewards add existing card

- Run: `20260908T083732-59560`
- Web: `http://127.0.0.1:59151`
- API: `http://127.0.0.1:49463`
- Owner: `verifier` via the setup form (not `POST /api/auth/setup`)

## Drive

1. Empty Rewards on All. Copy: choose Add card to score one of your HowMuch cards. `empty.png`.
2. Add card `/rewards/new`. Section Existing HowMuch card. HowMuch card picker options: Choose a HowMuch card, Travel Card (`acct-credit`). Everyday Account and Rainy Day Saver are absent. `new-blank.png` / `new.json`.
3. Choose Travel Card. Name fills to Travel Card. Issuer UOB. Type Cashback. Earning rate 1. `new.png` / `filled.json`.
4. Save card. Board Cashback tile is Travel Card / UOB · Travel Card. Qualifying spend `$830.80` / `$8.31`. No invented Verify cashback name. `created.png`.
5. HTTP `GET /api/import/rewards-tracker?plan_id=local-plan`: one card named `Travel Card`, `ynabAccountId` `acct-credit`. Card was not POSTed from `control-howmuch http`.

## Flag colour tags

Editor FlagPicker is the ledger control: None, Red, Orange, Yellow, Green, Blue, Purple. Same swatches on the account ledger. Dining Out + Red stores `flagColor: "red"`. None stores `unflagged`.

After save, the Travel Card tile uses `flag-tag flag-tag-red` for Dining Out at 4×. Qualifying spend is `$601.90` (the three red Travel Card rows) and value `$24.08`. By flag uses the same red Dining and blue Online tags as the register. `flags.png` / `flagged-board.png` / `flag-tag.json`.

Linux cannot run `scripts/ios-xcodebuild.sh`. iOS picker uses the same unused credit-card filter and the same ledger FlagColour tags (None plus the six colours).
