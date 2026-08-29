# Age of Money

Age of Money estimates how many days income sat before it was spent. The default range is all history, so the demo always has a figure.

## Sub-features

- `aom-open` opens the report from Primary navigation and from `/age-of-money`.
- `aom-default-all` shows a latest age in days on the default all-time window.
- `aom-history` lists periods with Spending matched and optional unmatched spending.
- `aom-this-month-empty` shows no spending when the range is an empty current month.

## How to get to it (user POV)

- Choose **Age of Money** in Primary navigation.
- Open `{web_url}/age-of-money` with no query string.
- Keep the current query string when moving from another Reflect tab.

## Driving it with control-howmuch

Preconditions:

- `control-howmuch doctor` passes.
- Owner `verifier` is signed in.
- Demo ledger still contains both inflows and outflows.

- **Open report.** Open `{web_url}/age-of-money` (no query). Title is `Age of Money · HowMuch`. Heading is `Age of money`. Filter rail hides the category picker. Active preset is `All`.
- **Default figure.** Latest headline is `{n} days` (not `—`). `Spending matched` is non-zero. History includes Mar / Apr / May 2026.
- **This month empty.** Choose `This month`. If today is outside March–May 2026, status title is `No spending in this range.` with detail `Need both income and spending before age of money can be calculated.`
- **Return to All.** Choose `All`. The days figure returns.
- **HTTP match.** `control-howmuch http GET "/api/reports/age-of-money?plan_id=local-plan"` returns `data.periods` with at least one `age_of_money_days` that is not null.
- **Proof.** Screenshot the populated All report (`artifacts/age-of-money/all-range.png`) and save the HTTP JSON (`artifacts/age-of-money/report.json`).

## Gotchas

- A clipped window (This month, leftover spending dates) makes the age look empty or distorted. The page defaults to all history on purpose.
- Category filters are ignored. The page does not show a category control.
- Unmatched spending is income-less outflow from before the first inflow. A diagnostic note appears only when that total is above zero.
- Heading casing is `Age of money`; the nav link and document title use `Age of Money`.
