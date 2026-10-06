# Income v spending

Income v spending totals inflows against outflows by period. The default range is year-to-date, so a 2026-08 visit still shows the March–May demo. This month is the empty path.

## Sub-features

- `income-open` opens the report from the **Reports** group in Primary navigation and from `/income`.
- `income-default-ytd` shows demo income and spending on the default YTD window.
- `income-this-month-empty` shows no activity when the range is the current empty month.
- `income-all` matches YTD totals when the demo is the only history.
- `income-headlines` shows Income, Spending, Net, and Savings rate.
- `income-legend` keys the Trend chart with **Income** and **Spending** swatches.

## How to get to it (user POV)

- Choose **Income v spending** in the **Reports** group of Primary navigation.
- Open `{web_url}/income` with no query string.
- Keep the current query string when moving from another Reports link.

## Driving it with control-howmuch

Preconditions:

- `control-howmuch doctor` passes.
- Owner `verifier` is signed in.
- Demo ledger still contains the seeded March–May 2026 rows.

- **Open report.** Open `{web_url}/income` (no query). Title is `Income v spending · Halation`. Heading is `Income v spending`. Filter rail shows group `Date range`.
- **Default YTD.** Active preset is `YTD`. Headlines: Income `$16,970.00`, Spending `$3,292.30`, Net `+$13,677.70`, Savings rate `80.6%`. History lists Mar / Apr / May 2026. Status `No activity in this range.` is absent.
- **This month empty.** Choose `This month`. If today is outside March–May 2026, status title is `No activity in this range.` with detail `Try widening the date range or clearing account filters.`
- **All range.** Choose `All`. Income and Spending return to the YTD figures. Section `Trend` shows more than one period, with a key list `Chart key` reading `Income` and `Spending`.
- **HTTP match.** `control-howmuch http GET "/api/reports/income-vs-spending?plan_id=local-plan&from=2026-03-01&to=2026-05-31"` returns `data.periods` whose income values sum to `16970000` and spending values sum to `3292300`.
- **Proof.** Screenshot the populated YTD or All report (`artifacts/income-v-spending/ytd.png`) and save the HTTP JSON (`artifacts/income-v-spending/report.json`).

## Gotchas

- Unlike Spending breakdown, the default is YTD, not this month. An empty first paint here is leftover `from`/`to` from another tab, or you clicked **This month**.
- Reports links keep `location.search`. Load `/income` with no query to prove the YTD default.
- Investing inflows (Broker transfer) count as income. They are positive amounts, not envelope assignments.
- Heading, nav link and document title all read `Income v spending`.
- On a viewport ≤720px the filter rail sits behind **Filters ▾**. Open it before choosing `This month` or `All`.
