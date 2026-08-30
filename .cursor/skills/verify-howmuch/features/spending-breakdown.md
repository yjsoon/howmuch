# Spending breakdown

Spending breakdown totals outflows by category. The default range is this calendar month, so a 2026-08 visit shows an empty report until the user chooses **All** or March–May 2026.

## Sub-features

- `spending-open` opens the report from Primary navigation and from `/spending`.
- `spending-default-empty` shows a zero/empty current-month report when today is outside the demo span.
- `spending-all` shows demo outflows after choosing **All**.
- `spending-custom-range` matches **All** when From/To cover 2026-03-01 … 2026-05-31.
- `spending-drill` opens the register filtered to one category.

## How to get to it (user POV)

- Choose **Spending breakdown** in Primary navigation.
- Open `{web_url}/spending`.
- Keep the current query string when moving from another report tab.

## Driving it with control-howmuch

Preconditions:

- `control-howmuch doctor` passes.
- Owner `verifier` is signed in.
- Demo ledger still contains the seeded March–May 2026 outflows.

- **Open report.** Choose `Spending breakdown`. Title is `Spending breakdown · HowMuch`. Heading is `Spending breakdown`. Filter rail shows group `Date range`.
- **Default empty.** If today is 2026-08 (or any month outside March–May 2026) and the active preset is `This month`, `Total spending` is `$0.00` and largest line is `-`. Status title `No spending in this range.` with detail `Adjust the dates or clear category filters to show more transactions.` Groceries is absent. This is the correct empty state. Headline `Average transaction` is also present.
- **All range.** Choose `All` in `Date range`. URL becomes `/spending?range=all`. `Total spending` is `$3,292.30`. Largest line is `Utilities`. Category detail lists Home (`Utilities` `$1,974.50`, `Groceries` `$357.10`, `Dining Out` `$125.40`), Travel (`Holiday` `$488.90`), and Living (`Shopping`, `Health`, `Transport`).
- **Custom range.** Choose `From date` `2026-03-01` and `To date` `2026-05-31`. Groceries remains visible. Summary text includes those dates.
- **HTTP match.** `control-howmuch http GET "/api/reports/spending-breakdown?plan_id=local-plan&from=2026-03-01&to=2026-05-31"` returns `data.total > 0` and a group whose `category_name` is `Groceries`.
- **Drill-down.** Choose the `Groceries` category link. The register opens on `/transactions` with Groceries in scope. FairPrice Finest and/or Cold Storage rows are visible once the register range includes their dates (the drill link carries the report's from/to).
- **Proof.** Screenshot the populated All (or custom) report (`artifacts/spending-breakdown/all-range.png`) and save the HTTP JSON (`artifacts/spending-breakdown/report.json`). Both must show Groceries and a non-zero total.

## Gotchas

- Proving spending on `This month` in 2026-08 is a false fail. Switch to `All` or the demo dates first.
- `Include` / `Exclude` toggles hidden & non-personal categories. Demo groups are ordinary (Home, Living, Travel); leave the toggle alone unless you are proving it.
- Filter query strings persist across Reflect tabs. Leftover `from`/`to` from another report can hide the empty-default sub-feature. Use `This month` or a fresh load of `/spending` with no query to prove that path.
- Report amounts are absolute outflows. Income (Tinkermind Payroll) does not appear here.
