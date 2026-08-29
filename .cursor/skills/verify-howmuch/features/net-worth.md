# Net Worth

Net Worth is a period series of account balances plus a headline for the latest close. The default range is the trailing year, which includes the March–May 2026 demo.

## Sub-features

- `net-worth-open` opens the report from Primary navigation and from `/net-worth`.
- `net-worth-default` shows a non-zero latest net worth on the trailing-year window.
- `net-worth-accounts` lists Everyday Account, Rainy Day Saver, and Travel Card as columns.
- `net-worth-this-month-empty` can show no history when the current month has no closing snapshots in range.

## How to get to it (user POV)

- Choose **Net Worth** in Primary navigation.
- Open `{web_url}/net-worth` with no query string.
- Keep the current query string when moving from another Reflect tab.

## Driving it with control-howmuch

Preconditions:

- `control-howmuch doctor` passes.
- Owner `verifier` is signed in.
- Demo accounts and opening balances are still seeded.

- **Open report.** Open `{web_url}/net-worth` (no query). Title is `Net Worth · HowMuch`. Heading is `Net worth`. Filter rail hides the category picker.
- **Default trailing year.** Active preset is `1Y`. Latest net worth is `$554,677.70`. `Tracked accounts` is `3`. Table columns include Everyday Account, Rainy Day Saver, and Travel Card.
- **All range.** Choose `All` if the trailing year looks thin. Latest net worth stays non-zero. Section `Trend` is present.
- **HTTP match.** `control-howmuch http GET "/api/reports/net-worth?plan_id=local-plan&from=2026-03-01&to=2026-05-31"` returns `data.periods` whose last `net_worth` is non-zero and whose `accounts` include `acct-everyday`.
- **Proof.** Screenshot the populated report (`artifacts/net-worth/trailing-year.png`) and save the HTTP JSON (`artifacts/net-worth/report.json`).

## Gotchas

- Category filters are ignored. The page does not show a category control.
- Leftover `from`/`to` for this month in 2026-08 can empty the series. Load `/net-worth` with no query, or choose `1Y` / `All`.
- Closed accounts can appear in history but drop out of the “active columns” if their balance stays `0` in the window.
- Heading casing is `Net worth`; the nav link and document title use `Net Worth`.
