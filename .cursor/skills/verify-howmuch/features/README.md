# HowMuch verification map

This directory is the maintained source for verifying the user-facing behaviour of HowMuch's web app. Read the index before driving, then use the matching feature file as the recipe.

## Baseline preconditions

- Launch with `control-howmuch launch` and require `control-howmuch doctor` to pass.
- Drive only `{web_url}` from `control-howmuch state`. Refuse `http://127.0.0.1:5173` / `:8787` unless doctor says this run owns them and the database is under `/tmp/howmuch-verify/`.
- Seed is `fixtures/demo-ledger.json`: plan `HowMuch Demo` (`local-plan`), accounts **Everyday Account**, **Rainy Day Saver**, **Travel Card**, categories including Groceries / Dining Out / Utilities / Holiday, payees including FairPrice Finest, Candlenut, Scoot.
- Demo transactions run **2026-03-01 … 2026-05-24**. Default UI ranges follow today, so they look empty until you choose **All** or that date span.
- First paint is **Set up HowMuch** (no user yet). Create `verifier` / `howmuch-verify-15` with setup token `howmuch-verify-bootstrap`.
- Never drive an instance this run did not start.

## Driving conventions

- Start every recipe from the baseline unless its preconditions say otherwise.
- Prefer accessible names and routes. On a viewport ≤720px, open **Open menu** before sidebar links.
- Treat commands as literal. Keep quoted names unchanged.
- Browser actions go through Cursor browser / computer-use against `{web_url}`.
- Ledger reads go through `control-howmuch http`.
- Restore leftover UI state (open menus, editors) before the next recipe. Do not delete proof artifacts.

## Proof and skip reporting

- Capture the user action and the resulting state, not only the final screen.
- UI proof: screenshot with HowMuch identity visible (`HowMuch` masthead or `{page} · HowMuch` title) plus a note of the heading and key figures.
- Mutation proof: a second view — register row, **Saved this session**, or `control-howmuch http` JSON.
- Record the feature id and entry point with every artifact.
- Report an unreachable path with the attempted handle and the unmet precondition.
- Do not report a skipped entry point as verified through a different path.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the user-visible behaviour. It then uses exactly four H2 sections in this order.

1. `Sub-features` lists short IDs with one line for each behaviour.
2. `How to get to it (user POV)` lists every user entry point.
3. `Driving it with control-howmuch` starts with `Preconditions:` and uses labeled bullets that pair each user action with an exact command or handle and an observable result.
4. `Gotchas` lists traps that can waste or invalidate a verification run.

Keep implementation details out of the map. Name only user paths, stable handles, required state, commands, and observable proof.

## Features

- [First-owner setup](./first-owner-setup.md) covers the empty-database account form, sign-in on a later visit, sign out, and that signed-in home has no Plan.
- [Spending breakdown](./spending-breakdown.md) covers the empty current-month default, All-range totals, and category drill-down.
- [Income v Spending](./income-v-spending.md) covers the YTD default, This-month empty state, and income versus spending headlines.
- [Net Worth](./net-worth.md) covers the trailing-year series and per-account balance columns.
- [Age of Money](./age-of-money.md) covers the all-history default and the latest age in days.
- [Transactions register](./transactions-register.md) covers All Accounts, payee search, and account-scoped register.
- [Register compose](./register-compose.md) covers the inline add row on an account register.
- [Register maintenance](./register-maintenance.md) covers the uncategorised pill, approval, inline edit, and opening Reconcile.
- [Quick entry](./quick-entry.md) covers posting a spend from `/add` and seeing it in the register.
- [Scheduled transactions](./scheduled-transactions.md) covers the empty demo list, adding a monthly schedule, and entering it.
- [API tokens](./api-tokens.md) covers minting a personal token and revoking it.
- [Organise accounts](./organise-accounts.md) covers favourites, a custom group, and the sidebar after close.
