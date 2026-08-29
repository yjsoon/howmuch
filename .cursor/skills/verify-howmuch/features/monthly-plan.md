# Monthly plan

Plan is the monthly assignment sheet: Ready to assign, Assigned, Activity, and per-category assigned/available/target. Assignments save immediately and survive a reload.

## Sub-features

- `plan-open` opens Plan from `/` (redirect) and from the Plan nav link.
- `plan-month` steps between months without leaving Plan.
- `plan-empty-activity` shows $0.00 activity for a month with no demo rows (e.g. the current month in 2026-08).
- `plan-activity` shows non-zero Activity after stepping to May 2026.
- `plan-assign` edits Groceries' assigned amount and keeps the value after reload.

## How to get to it (user POV)

- Open `{web_url}` / `{web_url}/` — redirects to `/plan`.
- Choose **Plan** in Primary navigation.
- Open `{web_url}/plan` directly.

## Driving it with control-howmuch

Preconditions:

- `control-howmuch doctor` passes.
- Owner `verifier` is signed in (see first-owner-setup).
- Demo categories include Groceries.

- **Redirect entry.** Open `{web_url}/`. Title becomes `Plan · HowMuch`. Heading is `Plan`. Region `Plan summary` shows `Ready to assign`, `Assigned`, and `Activity`.
- **Nav entry.** Choose `Spending breakdown`, then `Plan`. Plan returns. Query string from the report, if any, is preserved on the Plan link.
- **Current month.** Group `Plan month` shows today's month name. Groceries is listed. Activity for Groceries is `0.00` when the month is outside March–May 2026.
- **May 2026 activity.** Choose `Previous month` until the label is `May 2026`. Groceries Activity is not `0.00` (demo has Cold Storage on 2026-05-08).
- **Assign Groceries.** Return to the current month with `Current`. Choose `Edit assigned amount for Groceries`. Type `50` in `Assigned amount for Groceries`. Choose `Save`. The Groceries assigned cell reads `50.00` (currency symbol may prefix).
- **Confirm persistence.** Reload `/plan`. Groceries still shows assigned `50.00`. `control-howmuch http GET /v1/plans/local-plan/months/{YYYY-MM}` for the current month includes Groceries `budgeted` of `50000` milliunits.
- **Proof.** Screenshot current-month Plan with Groceries assigned (`artifacts/monthly-plan/groceries-assigned.png`) and save the month JSON beside it.

## Gotchas

- Demo activity lives in March–May 2026 only. A current-month Activity of `0.00` is correct in August 2026.
- Bookkeeping/inflow groups sit behind `Show bookkeeping categories`. Groceries is not there.
- Click the assigned amount, not the Groceries name. The name is a drill-link to the register.
- `Save` is the assignment submit; `Cancel` discards the draft and must leave the previous value.
- Month state is React state, not the URL. Reload jumps back to the current month.
