# Transactions register

The register is a dense list of ledger rows with the same filter rail as reports, plus payee/memo search. **Ledger** (every account) and each sidebar account are separate entry points. The header leads with the working balance; cleared and uncleared sit on one line beneath it. Posted future-dated rows and recurrences sit behind a closed **Scheduled** disclosure; the table itself is today and backwards.

## Sub-features

- `register-all` opens every account via **Ledger**.
- `register-account` opens one account from the sidebar (Everyday Account).
- `register-default-empty` is empty on the default trailing-two-month window when today is 2026-08.
- `register-search` finds rows by payee, memo, category, account, or amount as it appears (`142.30`, `142`, `$142.30`), including older transactions than the ones already on screen.
- `register-balances` shows the working balance as the header figure, with `{cleared} cleared · {uncleared} uncleared` beneath it. A single-account register adds `{amount} as of today` when posted future-dated rows exist, and `Last reconciled {date}` once the account has been reconciled.
- `register-scheduled` shows a closed **Scheduled** disclosure on Ledger and on an account register when recurrences or posted futures exist.

## How to get to it (user POV)

- Choose **Ledger**, the first item in Primary navigation (`/transactions?range=all&accounts=all`).
- Choose **Everyday Account** (or another account name) in the sidebar account list.
- Follow a report category drill-link to `/transactions` with `category_ids` and dates set.

## Driving it with control-howmuch

Preconditions:

- `control-howmuch doctor` passes.
- Owner `verifier` is signed in.
- Seeded payee `FairPrice Finest` still exists.

- **Ledger.** Choose `Ledger`. Title is `Ledger · Halation`. Heading / register label is `Ledger`. The header figure is labelled `Working balance` (`$554,677.70` on the fresh seed) with `$541,000.00 cleared · $13,677.70 uncleared` beneath it. There is no `+` / `=` equation.
- **See demo rows.** `Ledger` already sets `range=all`. FairPrice Finest, Candlenut, and Scoot are visible without another range click. If you arrived via `/transactions` with no `range=all`, choose `All` in `Date range` first.
- **Search.** Type `FairPrice` into `Search transactions`. Visible rows are FairPrice Finest only (Scoot and Candlenut gone). Search meta names the match count without saying the list is only what is already loaded.
- **Amount search.** Clear the box, then type `142.30`. FairPrice Finest (`$142.30`) remains. Repeat with `142` and `$142.30`. Meta still must not say “Scroll”.
- **Clear search.** Clear the searchbox. Scoot returns.
- **Account scope.** Choose `Everyday Account`. Title becomes `Everyday Account · Halation`. The header figure becomes that account's working balance (`$198,008.50` on the fresh seed). Travel Card spend (Scoot, Candlenut) is absent. FairPrice Finest remains.
- **HTTP match.** `control-howmuch http GET "/v1/plans/local-plan/transactions?since_date=2026-03-01&until_date=2026-05-31"` returns a transaction whose `payee_name` is `FairPrice Finest`.
- **Proof.** Screenshot Ledger with FairPrice visible (`artifacts/transactions-register/all-accounts.png`) and the FairPrice search state (`artifacts/transactions-register/search-fairprice.png`).

## Gotchas

- Bare `/transactions` defaults to the last two months. In 2026-08 that window is empty. Use **Ledger** or `range=all`, not the default.
- Search queries the plan, not only the rows already on screen. Amounts match as displayed money (`142.30`), not as milliunit digit strings. On iOS the extra control is **Load older matches**, never scroll.
- On iOS the register opens with no search field. Tap the magnifier (**Search**) in the top bar to show it; **Cancel** with an empty field hides it again.
- Multi-account filtered views may say `Load older entries to extend this multi-account result.` Use the button if a row you expect is missing.
- Sidebar **Travel Card** is a credit account. Its outflows are on that register, not Everyday Account.
- Choosing **Ledger** after an account scope is the way back; the browser Back button also works but leaves leftover query params.
- The seeded demo has no posted future-dated rows and no reconciliation, so `as of today` and `Last reconciled` are absent until you post a future-dated row or reconcile. They never appear on Ledger or a multi-account view.
- Flags, scheduled disclosure, approve, uncategorised, reconcile, and inline edit of existing rows live on this page. Drive those via [Register maintenance](./register-maintenance.md), not this recipe.
