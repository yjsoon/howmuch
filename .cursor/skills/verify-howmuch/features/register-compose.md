# Register compose

On a register, **+ Add transaction** opens an inline row. The posting account is the account you are viewing. Save writes that account and leaves you on the register.

## Sub-features

- `compose-open` opens the inline row from **+ Add transaction** on Everyday Account.
- `compose-account-lock` shows Everyday Account as the posting account, not a picker defaulting to another account.
- `compose-save` saves an outflow and shows the new row on that register.
- `compose-add-another` keeps the row open after **Save and add another**.
- `compose-all-accounts` on All Accounts still posts to the account chosen in the row.

## How to get to it (user POV)

- Choose **Everyday Account** in the sidebar, then **+ Add transaction** in the register toolbar.
- Choose **All Accounts**, then **+ Add transaction**, then pick an account in the row.

## Driving it with control-howmuch

Preconditions:

- `control-howmuch doctor` passes.
- Owner `verifier` is signed in.
- Everyday Account is open (seeded).
- Use payee `Inline Toast Verify` so the row is unique.

- **Open account register.** Choose `Everyday Account`. Title is `Everyday Account · HowMuch`.
- **Open compose.** Choose `+ Add transaction` in the register toolbar. The first register row is the compose form. Date is focused. Account cell reads `Everyday Account`. There is no account `<select>`.
- **Fill outflow.** Date `Today`. Payee `Inline Toast Verify`. Category `Dining Out` if offered, otherwise leave Uncategorised. Memo `verify inline compose`. Outflow `4.20`. Leave Inflow empty.
- **Save.** Choose `Save`. Status `Inline Toast Verify saved.` The compose row closes. A register row for `Inline Toast Verify` shows today's date and outflow `4.20` on Everyday Account.
- **Add another.** Choose `+ Add transaction` again. Fill payee `Inline Toast Two` and outflow `1.10`. Choose `Save and add another`. The first row stays a compose form. Payee is empty. Account is still Everyday Account.
- **Cancel.** Choose `Cancel`. The compose row closes.
- **HTTP match.** `control-howmuch http GET "/v1/plans/local-plan/transactions?since_date={today}&until_date={today}"` includes `payee_name` `Inline Toast Verify`, `account_id` `acct-everyday`, and `amount` `-4200`.
- **Sidebar fallback.** Stay on Everyday Account. Choose sidebar `+ Add transaction`. Title is `Quick entry · HowMuch`. Posting account reads `Everyday Account`.
- **Proof.** Screenshot the open compose row (`artifacts/register-compose/open.png`) and the saved Everyday Account row (`artifacts/register-compose/saved.png`). Keep the HTTP JSON (`artifacts/register-compose/transaction.json`).

## Gotchas

- Register **+ Add transaction** no longer navigates to `/add`. The sidebar footer and mobile **+ Add** still do.
- Demo rows sit in 2026-03 through 2026-05. A save dated today appears on the default two-month window. A back-dated save needs **All** or a matching From/To.
- Outflow and inflow clear each other. Do not fill both.
- Travel Card is a different account. A compose opened there must post to `acct-credit`, not Everyday Account.
