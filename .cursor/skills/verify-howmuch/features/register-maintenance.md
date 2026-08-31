# Register maintenance

The register can approve new rows, filter uncategorised lines, reconcile an account, and edit a posted row in place. Demo seed rows are already approved and categorised, so this recipe posts one messy row first.

## Sub-features

- `maintain-uncategorised` shows the uncategorised pill after a row with no category.
- `maintain-approve` shows `{n} new to approve` when a row is not approved.
- `maintain-edit` double-clicks the `Needs Category Verify` row (the category cell is a fine hit target). Every editable field becomes a control. Choose Dining Out. Save or Approve. The row reads Dining Out. There is no Edit button and no transaction panel. Escape or Cancel discards.
- `maintain-flag` double-clicks the same row, or a new unique one. Choose flag Red. Save. The idle row shows Red. HTTP `flag_color` is `red`.
- `maintain-transfer` double-clicks a unique non-transfer Everyday Account row. Compose `Transfer List Verify` with outflow `2.20` if needed. Open payee. The list includes `Transfer to Rainy Day Saver`, or the option value `Transfer : Rainy Day Saver`. Choose it. The category cell reads Transfer. Save. HTTP `transfer_account_id` is the Rainy Day Saver account id. Look that id up from accounts if needed. Demo accounts are Everyday Account, Rainy Day Saver, and Travel Card. Do not transfer to Everyday Account from Everyday Account. A saved transfer can become a regular payee. It cannot be pointed at a different account.
- `maintain-reconcile-open` opens **Reconcile account** and cancels without writing.

## How to get to it (user POV)

- Open **Everyday Account**, then use the register toolbar.
- The uncategorised and approval pills appear above search once counts are above zero.

## Driving it with control-howmuch

Preconditions:

- `control-howmuch doctor` passes.
- Owner `verifier` is signed in.
- Everyday Account is open.
- Use payee `Needs Category Verify` so the row is unique.

- **Compose messy row.** On Everyday Account choose `+ Add transaction`. Payee `Needs Category Verify`. Outflow `3.40`. Leave category Uncategorised. Save. Toast includes `Needs Category Verify saved.`
- **Pills.** Toolbar shows `1 uncategorised`. If the new row is unapproved, also `{n} new to approve`.
- **Filter.** Choose `1 uncategorised`. The register shows `Needs Category Verify`. Control reads `Showing uncategorised · clear`.
- **Edit.** Double-click the `Needs Category Verify` row. The category cell is a fine hit target. Every editable field on that row becomes a control. Choose `Dining Out`. Save or Approve. The category cell and row read `Dining Out`. The row then leaves this uncategorised list. Choose `Showing uncategorised · clear`. The row is back with Dining Out. There is no Edit button and no Edit transaction panel. Escape or Cancel discards the draft.
- **Flag.** Double-click the same row, or a new unique one. Choose flag Red. Save. Idle `FlagTag` reads Red. HTTP `flag_color` is `red`.
- **Transfer.** Double-click a unique non-transfer Everyday Account row. Compose `Transfer List Verify` with outflow `2.20` if that row is not already there. Open payee. The list includes `Transfer to Rainy Day Saver`, or the option value `Transfer : Rainy Day Saver`. Choose it. The category cell reads Transfer. Save. HTTP `transfer_account_id` is the Rainy Day Saver account id. Look that id up from accounts if needed. Do not transfer to Everyday Account from Everyday Account.
- **Reconcile open.** Choose `Reconcile account`. Heading is `Reconcile account`. Fields `Account`, statement date, and statement balance are present. Choose `Cancel`. The editor closes. Working balance is unchanged.
- **HTTP match.** `control-howmuch http GET "/v1/plans/local-plan/transactions?since_date={today}&until_date={today}"` includes `payee_name` `Needs Category Verify`, `amount` `-3400`, a non-null `category_id` after save, and `flag_color` `red` after the flag save. After the transfer save, the `Transfer List Verify` row has `transfer_account_id` set to the Rainy Day Saver account id.
- **Proof.** Screenshot the uncategorised pill (`artifacts/register-maintenance/uncategorised.png`), the category cell after Dining Out (`artifacts/register-maintenance/edit.png`), idle `FlagTag` Red (`artifacts/register-maintenance/flag.png`), the Transfer category cell (`artifacts/register-maintenance/transfer.png`), and the open reconcile sheet (`artifacts/register-maintenance/reconcile.png`).

## Gotchas

- Seeded demo rows will not show these pills. Post the messy row first.
- Do not finish a reconciliation in this recipe. Confirm writes cleared/reconciled state and is easy to strand.
- Register toolbar `+ Add transaction` is compose, not `/add`.
- Search also matches memo and category. After you assign Dining Out, search `Needs Category` still finds the row.
- Double-click the row, not an Edit button. The category cell is a fine hit target. Every editable field becomes a control at once. There is no transaction panel.
- Do not transfer Everyday Account to itself.
