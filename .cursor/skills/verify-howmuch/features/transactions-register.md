# Transactions register

The register is a dense list of ledger rows with the same filter rail as reports, plus payee/memo search. All Accounts and each sidebar account are separate entry points.

## Sub-features

- `register-all` opens every account via **All Accounts**.
- `register-account` opens one account from the sidebar (Everyday Account).
- `register-default-empty` is empty on the default trailing-two-month window when today is 2026-08.
- `register-search` filters loaded rows by payee (FairPrice Finest).
- `register-balances` shows cleared / uncleared / working figures in the header.

## How to get to it (user POV)

- Choose **All Accounts** in Primary navigation (`/transactions?range=all&accounts=all`).
- Choose **Everyday Account** (or another account name) in the sidebar account list.
- Follow a report category drill-link to `/transactions` with `category_ids` and dates set.

## Driving it with control-howmuch

Preconditions:

- `control-howmuch doctor` passes.
- Owner `verifier` is signed in.
- Seeded payee `FairPrice Finest` still exists.

- **All Accounts.** Choose `All Accounts`. Title is `All Accounts · HowMuch`. Heading / register label is `All Accounts`. Header shows `Active cleared balance`, `Active uncleared balance`, `Active working balance`.
- **See demo rows.** `All Accounts` already sets `range=all`. FairPrice Finest, Candlenut, and Scoot are visible without another range click. If you arrived via `/transactions` with no `range=all`, choose `All` in `Date range` first.
- **Search.** Type `FairPrice` into `Search transactions`. Visible rows include `FairPrice Finest` and exclude `Scoot`. Search meta reads `Showing 1 of …` (or the loaded match count).
- **Clear search.** Clear the searchbox. Scoot returns.
- **Account scope.** Choose `Everyday Account`. Title becomes `Everyday Account · HowMuch`. Travel Card spend (Scoot, Candlenut) is absent. FairPrice Finest remains.
- **HTTP match.** `control-howmuch http GET "/v1/plans/local-plan/transactions?since_date=2026-03-01&until_date=2026-05-31"` returns a transaction whose `payee_name` is `FairPrice Finest`.
- **Proof.** Screenshot All Accounts with FairPrice visible (`artifacts/transactions-register/all-accounts.png`) and the FairPrice search state (`artifacts/transactions-register/search-fairprice.png`).

## Gotchas

- Bare `/transactions` defaults to the last two months. In 2026-08 that window is empty. Use **All Accounts** or `range=all`, not the default.
- Search is client-side over rows already loaded. It does not fetch older pages. Prove search after `range=all` so FairPrice is loaded.
- Multi-account filtered views may say `Load older entries to extend this multi-account result.` Scroll/load if a row you expect is missing.
- Sidebar **Travel Card** is a credit account. Its outflows are on that register, not Everyday Account.
- Choosing **All Accounts** after an account scope is the way back; the browser Back button also works but leaves leftover query params.
