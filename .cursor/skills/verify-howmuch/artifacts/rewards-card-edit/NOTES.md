# rewards-card-edit proof

- Feature: web native Rewards card manage
- Entry points: `{web_url}/rewards`, **Add card**, `/rewards/new`, tile → `/rewards/:cardId`
- Instance: `http://127.0.0.1:41407` (control-howmuch run `20260907T232549-10394`)
- Action: first-owner `verifier`, empty Rewards on All, Add card Verify cashback mapped to Travel Card at earning rate 1, add Dining Out red 4x and Shopping blue 3x, set minimum spend 99999, set maximum spend 1, delete, then 390px Add card.
- UI result: Cashback tile scored $830.80 spend. Flags listed Dining Out and Shopping. Minimum spend label showed $830.80 / $99,999.00. Capped tile left the board while `/rewards/card_5561ca61-f367-4fb8-9dac-9f22c99418f8` still opened Edit card. Delete returned the empty board. 390px Open menu still reached Add card and `/rewards/new`.
- Save to tile: 79 ms on this stack (budget 800 ms).
- Side effect: screenshots in this directory. Review copies at `/tmp/rewards-web-manage-review-add.png` and `/tmp/rewards-web-manage-review-flags.png`. Review video on run `20260908T001853-17256` at `/tmp/rewards-web-manage-review.mp4`.
- Billing-day 15 reload and fixture import were driven later on run `20260908T021240-43644` (see below).

## Live re-drive after the ledger-date fix

Headed Chrome on `control-howmuch` run `20260908T013559-32348` (`c206be2`): web `http://127.0.0.1:51915`, api `http://127.0.0.1:39787`. First-owner `verifier`. No Rewards Tracker JSON file.

- Editor ledger request is `/v1/plans/local-plan/accounts/acct-credit/transactions?limit=250` with no `since_date` / `until_date`.
- Rows newest first: 13 May 2026 Candlenut, 4 May 2026 MUJI, 12 Apr 2026 Scoot, 11 Mar 2026 Grab. Footer **Newest first**.
- Native **Verify cashback** on Travel Card scores `$830.80` spend / `$8.31` at earning rate 1. Dining Out red 4× then scores `$601.90` / `$24.08`.
- Save to tile 47 ms (budget 800 ms). Delete returns the empty board.

## Perf, Rewards load vs trunk

Travel Card stored from `fixtures/rewards-tracker-export.json` on both stacks. Head is this branch. Trunk is `773f86f` (`origin/main`) in `/tmp/howmuch-trunk`.

- Head: `HOWMUCH_VERIFY_STATE_ROOT=/tmp/howmuch-verify-head` run `head-perf`, web `http://127.0.0.1:42077`, api `http://127.0.0.1:35805`. `head-rewards.png` has **Add card** and miles valuation.
- Trunk: `HOWMUCH_VERIFY_STATE_ROOT=/tmp/howmuch-verify-trunk` run `trunk-perf`, web `http://127.0.0.1:57673`, api `http://127.0.0.1:38019`. `trunk-rewards.png` has Travel Card and Qualifying spend, no **Add card**.

Click-nav from All Accounts to Rewards until Qualifying spend and Travel Card, interleaved trunk/head × 3. `perf-click.json`.

| stack | samples (ms) | median |
| --- | --- | --- |
| trunk | 38, 33, 37 | 37 |
| head | 34, 37, 35 | 35 |

Head median − trunk median = −2 ms (budget +200 ms). Pass.

Hard `goto /rewards` until the same headline, interleaved trunk/head × 3. `perf-hard.json`. `head-load.png` / `trunk-load.png` are sample 1.

| stack | samples (ms) | median |
| --- | --- | --- |
| trunk | 457, 371, 366 | 371 |
| head | 468, 367, 351 | 367 |

Head median − trunk median = −4 ms (budget +200 ms). Pass.

## Live lanes 7–8 (billing-day 15 + import)

Headed Chrome on `control-howmuch` run `20260908T021240-43644` against this web editor: web `http://127.0.0.1:36013`, api `http://127.0.0.1:34083`. First-owner `verifier`. Never `howmuch.soon.sg`.

- Native **Verify cashback** on Travel Card (`acct-credit`), billing cycle `billing`, day of month `15`, earning rate `1`. Save returned to `/rewards?range=all`.
- Editor `/rewards/card_096150f6-aacb-4d2c-a7a1-e4caea679287` after a hard reload still shows heading **Edit card**, account Travel Card, Billing cycle **Billing cycle**, Day of month **15**. Ledger still newest first (13 May Candlenut → 11 Mar Grab). `web-billing-cycle.png`.
- Settings → Rewards import warned that a file replace soft-deletes omitted HowMuch cards (`web-import-warning.png`). Chose `fixtures/rewards-tracker-export.json`, **Import export**. Stored cards lists Travel Card (`web-import-still.png`).
- Rewards All then scores imported Travel Card miles `$830.80` / `$46.42` / 3,094 mi with Dining 4× and Online 3× (`web-import-board.png`). HTTP `GET /api/import/rewards-tracker?plan_id=local-plan` has `card-travel` miles; report flags Dining and Online, spend `830.8`.
