# ios-rewards-card-edit proof

- Feature: `ios-rewards-card-edit`
- Machine: howmuch-mac (`yjmbpro.local`), Darwin 25.6.0, macOS 26.6.2, Xcode 26.6 (17F113)
- Branch: `cursor/rewards-ios-manage-4825` @ `02a444c` plus this proof
- Simulator: HowMuch Verification (`BA2CAD1A-0977-4290-8486-760091B333AE`), bundle `sg.soon.howmuch`
- Instance: `control-howmuch` run `20260908T081041-32249`
  - web `http://127.0.0.1:58875`
  - api `http://127.0.0.1:58874` (never `howmuch.soon.sg`)
  - db `/tmp/howmuch-verify/20260908T081041-32249/howmuch.sqlite`
- Owner: first-owner setup in the web app as `verifier` / `howmuch-verify-15` / `howmuch-verify-bootstrap`. iOS Connection then signed in against that API.

## Unit

`scripts/ios-xcodebuild.sh build-for-testing` then `test -- -only-testing:HowMuchTests/RewardCardEditorTests -only-testing:HowMuchTests/RewardsReportTests`.

- `RewardCardEditorTests`: 4/4 passed (missing account, live `acct-credit` payload, billing/flag/tier round-trip, unknown flag colour → unflagged).
- `RewardsReportTests`: fixture dining flag `rewardEarned` is `1242`, not card-level `4154`. Assertion aligned to the fixture so the suite matches the JSON it decodes.

A first `test-without-building` against Sep 5 products executed 0 tests and was discarded.

## Simulator lanes

All Time throughout. Demo Travel Card spends remain 2026-03-01 through 2026-05-24.

1. **Empty.** Rewards tab: `No reward cards in this range.`, **Add card**, **Rewards import**. `empty.png`.
2. **Add card.** Sheet title Add card. Name / Issuer / Type / HowMuch account. `new.png`.
3. **Create.** Name `Verify cashback`, issuer `UOB`, type Cashback, account Travel Card, featured on, earning rate `1`, minimum spend `50`, Dining flag value `4`. Save returned to Rewards with a Cashback tile `Verify cashback`. Qualifying spend `$601.90`. `flags.png`, `created.png`.
4. **HTTP after create.** `GET /api/import/rewards-tracker?plan_id=local-plan` has one card `Verify cashback`, `ynabAccountId` `acct-credit`, min 50, rate 1, one subcategory. `created-snapshot.json`. Card was not POSTed from `control-howmuch http`.
5. **Edit / delete.** Tile opens Edit card, account Travel Card, ledger includes Candlenut and MUJI. Confirm `Delete this reward card?` → **Delete card**. Board empty again. HTTP cards `[]`. `edit.png`, `delete-confirm.png`, `after-delete.png`.
6. **Import.** Rewards import → Choose export → `fixtures/rewards-tracker-export.json` from On My iPhone → Import export. Cards 1, tag mappings 2, accounts upserted 1. Stored cards lists Travel Card. `imported.png`.
7. **Capped hidden.** Travel Card tile → Maximum spend `1` → Save. Board omits the Travel Card tile (groups remain). HTTP snapshot `maximumSpend: 1` on `card-travel` / `acct-credit`. `capped-hidden.png`, `capped-snapshot.json`.
8. **Import still opens it.** More → Connection settings → Rewards import → stored **Travel Card**. Editor title Edit card, account Travel Card. `capped-editor.png`.

Save-to-tile wall-clock from the first accessibility dump after Save was ~1.6s; each `axe describe-ui` call is about that long, so this is not a product 800ms measurement. The tile was present on the first dump.

## Not used as proof

- Web `/rewards` and `/rewards/new`.
- Production `https://howmuch.soon.sg` (Connection default was that URL; it was changed to `http://127.0.0.1:58874` before Sign in).
- Speedflight / device install.
