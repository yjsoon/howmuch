# rewards-card-edit proof

- Feature: web native Rewards card manage
- Entry points: `{web_url}/rewards`, **Add card**, `/rewards/new`, tile → `/rewards/:cardId`
- Instance: `http://127.0.0.1:41407` (control-howmuch run `20260907T232549-10394`)
- Action: first-owner `verifier`, empty Rewards on All, Add card Verify cashback mapped to Travel Card at earning rate 1, add Dining Out red 4x and Shopping blue 3x, set minimum spend 99999, set maximum spend 1, delete, then 390px Add card.
- UI result: Cashback tile scored $830.80 spend. Flags listed Dining Out and Shopping. Minimum spend label showed $830.80 / $99,999.00. Capped tile left the board while `/rewards/card_5561ca61-f367-4fb8-9dac-9f22c99418f8` still opened Edit card. Delete returned the empty board. 390px Open menu still reached Add card and `/rewards/new`.
- Save to tile: 79 ms on this stack (budget 800 ms).
- Side effect: screenshots in this directory. Review copies at `/tmp/rewards-web-manage-review-add.png` and `/tmp/rewards-web-manage-review-flags.png`. Review video on run `20260908T001853-17256` at `/tmp/rewards-web-manage-review.mp4`.
- Billing-day 15 reload was not driven; the editor field is present.

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
