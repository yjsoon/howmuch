# iOS add account

Accounts can create a new bank account or card on device. The trailing plus opens a sheet for name, type, opening balance, and icon, then writes `POST /v1/plans/{id}/accounts`. Credit and loan types store the entered amount owed as a negative balance.

## Sub-features

- `ios-add-account-open` opens **New Account** from the Accounts plus.
- `ios-add-account-card` creates a Credit Card with an amount owed and lists it under Credit.
- `ios-add-account-transfer` provisions a `Transfer : …` payee so capture can move money to the new account.
- `ios-add-account-empty` on a ledger with no accounts shows **No Accounts** with the same **New Account** button.

## How to get to it (user POV)

- On **Accounts**, choose trailing **New Account** (plus).
- On an empty Accounts list, choose **New Account** in the empty state.

## Driving it with control-howmuch

Preconditions:

- `control-howmuch doctor` passes.
- [iOS connection](./ios-connection.md) signed in as `verifier` against this stack.
- Everyday Account, Rainy Day Saver, and Travel Card are still listed unless driving `ios-add-account-empty`.
- Use name `Verify Card` so the row is unique.

- **Open.** On `Accounts`, choose `New Account`. Sheet title `New Account`. Leading `Cancel`. Fields `Name`, `Type` (`Checking` with the bank emoji), `Current balance`, `Icon`.
- **Card.** Name `Verify Card`. Type `Credit Card` (under `Budget`; footer mentions cards on the plan). Type row then reads `Credit Card`. Balance label becomes `Amount owed`. Enter `12.50`. Footnote `Listed as` a negative `12.50`. Leave the default card icon.
- **Save.** Trailing `Save` is enabled. Choose `Save`. Toast `Added Verify Card`. Sheet dismisses. Accounts lists `Verify Card` under `Credit` with a negative `12.50`.
- **HTTP match.** `control-howmuch http GET /v1/plans/local-plan/accounts` includes `name` `Verify Card`, `type` `creditCard`, `balance` `-12500`, `on_budget` true. `control-howmuch http GET /v1/plans/local-plan/payees` includes `Transfer : Verify Card` with that account id.
- **Capture destination.** Tab `Transaction`. Payee list includes `Transfer : Verify Card`. Cancel without saving.
- **Proof.** Screenshot the open sheet with Type Credit Card and Amount owed 12.50 (`artifacts/ios-add-account/sheet.png`) and Accounts with Verify Card under Credit (`artifacts/ios-add-account/accounts.png`). Keep the HTTP JSON (`artifacts/ios-add-account/account.json`).

## Gotchas

- Organise accounts still only manages groups. Creating a card or bank account is the Accounts plus, not New Group.
- Amount owed for cards and loans is typed positive; Accounts lists it negative. The sheet shows `Listed as` once the amount is non-zero.
- Checking, Savings, Cash, and Other Asset keep the entered current balance, including a minus for overdraft.
- An empty ledger hides All Transactions / Scheduled and shows **No Accounts** with **New Account**.
- iOS Simulator is required. Do not treat web as a substitute; web has no create-account sheet.
