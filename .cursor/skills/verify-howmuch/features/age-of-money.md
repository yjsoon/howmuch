# Money age

Money age (formerly Age of Money) estimates how many days income sat before it was spent. The default range is all history, so the demo always has a figure.

## Sub-features

- `aom-open` opens the report from the **Reports** group in Primary navigation and from `/age-of-money`.
- `aom-default-all` shows a latest age in days on the default all-time window.
- `aom-history` lists periods with Spending matched and optional unmatched spending.
- `aom-this-month-empty` shows no spending when the range is an empty current month.

## How to get to it (user POV)

- Choose **Money age** in the **Reports** group of Primary navigation.
- Open `{web_url}/age-of-money` with no query string.
- Keep the current query string when moving from another Reports link.

## Driving it with control-howmuch

Preconditions:

- `control-howmuch doctor` passes.
- Owner `verifier` is signed in.
- Demo ledger still contains both inflows and outflows.

- **Open report.** Open `{web_url}/age-of-money` (no query). Title is `Money age · Halation`. Heading is `Money age`. The **Reports** group is open with `Money age` marked current. Filter rail hides the category picker. Active preset is `All`.
- **Default figure.** Latest headline is `67 days` (May 2026 is the last measured demo month). `Spending matched` is `$3,292.30`. History includes Mar / Apr / May 2026.
- **This month empty.** Choose `This month`. If today is outside March–May 2026, status title is `No spending in this range.` with detail `Need both income and spending before age of money can be calculated.`
- **Return to All.** Choose `All`. The days figure returns.
- **HTTP match.** `control-howmuch http GET "/api/reports/age-of-money?plan_id=local-plan"` returns `data.periods` with at least one `age_of_money_days` that is not null.
- **Proof.** Screenshot the populated All report (`artifacts/age-of-money/all-range.png`) and save the HTTP JSON (`artifacts/age-of-money/report.json`).

## Gotchas

- A clipped window (This month, leftover spending dates) makes the age look empty or distorted. The page defaults to all history on purpose.
- Category filters are ignored. The page does not show a category control.
- Unmatched spending is income-less outflow from before the first inflow. A diagnostic note appears only when that total is above zero.
- Heading, nav link and document title all read `Money age`; the route is still `/age-of-money` and the History column still says `Age of money`. iOS still says Age of Money under Reflect.
- On a viewport ≤720px the filter rail sits behind **Filters ▾**. Open it before choosing `This month` or `All`.
