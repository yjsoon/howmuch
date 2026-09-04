# iOS edit account

An existing account’s name, type, and icon can be edited on device. Accounts rows and the register title open **Edit Account**, which writes `PATCH /v1/plans/{id}/accounts/{account_id}` with `name`, optional `icon`, and `type` only when the classification changed. Balances do not change.

## Sub-features

- `ios-edit-account-open` opens **Edit Account** from an Accounts row or the register title.
- `ios-edit-account-type` changes Everyday Account from Checking to Savings and keeps the balance.
- `ios-edit-account-tracking` shows the Budget / Tracking note when a type move crosses the plan.
- `ios-edit-account-http` matches `type` `savings` and unchanged `balance` after save.

## How to get to it (user POV)

- On **Accounts**, long-press a row and choose **Edit Account**.
- On **Accounts**, VoiceOver **Edit Account** on a row.
- On an account register, tap the title or overflow **Edit Account**.

## Driving it with control-howmuch

Preconditions:

- `control-howmuch doctor` passes.
- [iOS connection](./ios-connection.md) signed in as `verifier` against this stack.
- Everyday Account is still listed as a checking account.

- **Open.** On `Accounts`, long-press `Everyday Account` and choose `Edit Account`. Sheet title `Edit Account`. Fields `Name`, `Type` (`Checking`), `Icon`.
- **Type.** Open `Type`. Choose `Savings` (under `Budget`). Type row then reads `Savings`. No Budget / Tracking note.
- **Save.** Trailing `Save` is enabled. Choose `Save`. Sheet dismisses. Everyday Account stays under `Cash`.
- **HTTP match.** `control-howmuch http GET /v1/plans/local-plan/accounts` includes Everyday Account with `type` `savings`, `on_budget` true, and the same `balance` as before the edit.
- **Tracking note.** Open **Edit Account** again. Change Type to `Mortgage`. Footnote `Moves the account from Budget to Tracking. Balances do not change.` Cancel without saving.
- **Proof.** Screenshot the open sheet with Type Savings (`artifacts/ios-edit-account/sheet.png`) and the HTTP JSON (`artifacts/ios-edit-account/account.json`).

## Gotchas

- Name and icon still save during transition read-only. A type change is locked and shows the sheet error.
- Imported YNAB types such as `personalLoan` stay as their humanised label until a kind is picked. Picking one shows `Replaces the imported type “…”`.
- Changing type does not recategorise existing transfers.
- iOS Simulator is required. Web has no type editor.
