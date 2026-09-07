# rewards-card-edit proof

- Feature: web native Rewards card manage
- Entry points: `{web_url}/rewards`, **Add card**, `/rewards/new`, tile → `/rewards/:cardId`
- Instance: `http://127.0.0.1:41407` (control-howmuch run `20260907T232549-10394`)
- Action: first-owner `verifier`, empty Rewards on All, Add card Verify cashback mapped to Travel Card at earning rate 1, add Dining Out red 4x and Shopping blue 3x, set minimum spend 99999, set maximum spend 1, delete, then 390px Add card.
- UI result: Cashback tile scored $830.80 spend. Flags listed Dining Out and Shopping. Minimum spend label showed $830.80 / $99,999.00. Capped tile left the board while `/rewards/card_5561ca61-f367-4fb8-9dac-9f22c99418f8` still opened Edit card. Delete returned the empty board. 390px Open menu still reached Add card and `/rewards/new`.
- Save to tile: 79 ms on this stack (budget 800 ms).
- Side effect: screenshots in this directory. Review copies at `/tmp/rewards-web-manage-review-add.png` and `/tmp/rewards-web-manage-review-flags.png`.
- Not proved: interleaved trunk Rewards-load median. Head save is under budget. Billing-day 15 reload was not driven; the editor field is present.
