# Register maintenance

The register can approve new rows, filter uncategorised lines, reconcile an account, and edit a posted row in place. Demo seed rows are already approved and categorised, so this recipe posts one messy row first.

## Sub-features

- `maintain-uncategorised` shows the uncategorised pill after a row with no category.
- `maintain-approve` shows `{n} new to approve` when a row is not approved.
- `maintain-edit` double-clicks the category cell on the `Needs Category Verify` row, chooses Dining Out, and commits with Enter or blur. The Edit button still opens the panel.
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
- **Edit.** Double-click the category cell on `Needs Category Verify`. Choose `Dining Out`. Press Enter or click away. The cell reads `Dining Out`. Choose **Edit**. The transaction editor opens. Choose **Cancel**.
- **Clear filter.** Choose `Showing uncategorised · clear`. The pill is gone (or the count dropped).
- **Reconcile open.** Choose `Reconcile account`. Heading is `Reconcile account`. Fields `Account`, statement date, and statement balance are present. Choose `Cancel`. The editor closes. Working balance is unchanged.
- **HTTP match.** `control-howmuch http GET "/v1/plans/local-plan/transactions?since_date={today}&until_date={today}"` includes `payee_name` `Needs Category Verify`, `amount` `-3400`, and a non-null `category_id` after save.
- **Proof.** Screenshot the uncategorised pill (`artifacts/register-maintenance/uncategorised.png`), the editor (`artifacts/register-maintenance/edit.png`), and the open reconcile sheet (`artifacts/register-maintenance/reconcile.png`).

## Gotchas

- Seeded demo rows will not show these pills. Post the messy row first.
- Do not finish a reconciliation in this recipe. Confirm writes cleared/reconciled state and is easy to strand.
- Register toolbar `+ Add transaction` is compose, not `/add`.
- Search also matches memo and category. After you assign Dining Out, search `Needs Category` still finds the row.
- Double-click a cell, not the row. The Edit button is the only way to open the panel.
