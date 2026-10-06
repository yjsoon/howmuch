# Quick entry

Quick entry is the thumb-reach `/add` form. A spend needs amount, payee, and account; it posts to the selected account and appears under **Saved this session**.

## Sub-features

- `quick-open` opens `/add` directly and from the mobile **+ Add** control.
- `quick-spend` saves a spend and shows **Saved.**
- `quick-recent` lists the new payee under **Saved this session**.
- `quick-register` shows the same row on the account register after save, reached with **‹ Ledger**.
- `quick-disabled` keeps **Save spend** disabled until amount and payee are valid.

## How to get to it (user POV)

- Open `{web_url}/add` directly (the desktop sidebar has no link to it).
- Choose **+ Add** in the mobile masthead (viewport ≤720px).
- From an account register, the masthead **+ Add** keeps `?account=` so the posting account matches that register. The register toolbar **+ Add transaction** opens the inline row instead. See [Register compose](./register-compose.md).

## Driving it with control-howmuch

Preconditions:

- `control-howmuch doctor` passes.
- Owner `verifier` is signed in.
- Everyday Account is open (seeded).
- No existing payee `Toast Box Verify` is required; use that exact name so the row is unique.

- **Open form.** Open `{web_url}/add`. Title is `Quick entry · Halation`. Heading text is `Quick entry`. Group `Direction` has `Spend` selected. Posting account reads `Everyday Account` unless changed.
- **Disabled save.** Leave Amount and Payee empty. `Save spend` is disabled.
- **Fill spend.** Amount `6.80`. Payee `Toast Box Verify`. Account `Everyday Account`. Date `Today`. Memo `verify quick entry`.
- **Save.** Choose `Save spend`. Status title `Saved.` and detail `Toast Box Verify saved.` Region `Saved this session` lists `Toast Box Verify` with a negative amount.
- **Register check.** Choose `‹ Ledger` (it opens `/transactions?range=all&accounts=all`), or open `/transactions?range=all&accounts=acct-everyday`. Search `Toast Box Verify`. The row is there with today's date.
- **HTTP match.** `control-howmuch http GET "/v1/plans/local-plan/transactions?since_date={today}&until_date={today}"` includes `payee_name` `Toast Box Verify` and `amount` `-6800`.
- **Proof.** Screenshot the Saved panel (`artifacts/quick-entry/saved.png`) and the register row (`artifacts/quick-entry/register.png`). Keep the HTTP JSON (`artifacts/quick-entry/transaction.json`).

## Gotchas

- `/add` is outside the main shell. There is no sidebar. Use `‹ Ledger` or a full URL to leave.
- At 390px the `Today` / `Yest.` shortcuts sit beside the date field without pushing the page wider, and Memo takes its own full-width row.
- Amount is unsigned in the field; `Spend` writes a negative. `Income` writes a positive. Do not type `-6.80`.
- `Save spend` stays disabled when the amount is `0` or the payee is blank.
- Retries of a failed submit reuse one `client_id`. A successful save mints a new one. Double-clicking Save after success starts a blank form, not a duplicate of the last id.
- Date follows the machine's local calendar, not UTC. Use the `Today` shortcut rather than inventing a date.
- Transfer and split paths are separate sub-features; this recipe is the spend path only. Do not mark those verified by completing a simple spend.
- This is the web `/add` form. It does not prove iOS Add Transaction, compose intake, or Shortcuts. Those are the `ios-*` recipes.
