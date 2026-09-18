# iOS capture

The existing Add Transaction sheet is the confirmation UI. Tab +, Duplicate for Today, and the home-screen Add Expense Quick Action all open it. Save writes through the outbox; nothing is recorded until **Save**. After #98 those doors share one `CaptureRequest`; behaviour for a human stays the same.

## Sub-features

- `capture-open-plus` opens a blank Add Transaction sheet from the tab-row Add Transaction plus.
- `capture-keypad` shows the glass keypad while amount is 0 and hides trailing Save.
- `capture-save` saves an outflow with amount + account (payee optional) and shows a Saved toast.
- `capture-register` shows that row on Everyday Account after save.
- `capture-duplicate` opens Duplicate for Today prefilled, keypad hidden when amount > 0, title still Add Transaction.
- `capture-quick-action` opens a blank sheet from home-screen Quick Action **Add Expense**.
- `capture-edit-has-no-compose` on an existing row’s editor: title **Transaction**, no compose field (once compose exists on Add).

## How to get to it (user POV)

- Tap the tab-row **Add Transaction** plus.
- Long-press a register row → **Duplicate for Today**.
- Long-press the HowMuch home-screen icon → **Add Expense**.
- After #98: a second present while the sheet is up replaces the form.

## Driving it with control-howmuch

Preconditions:

- `control-howmuch doctor` passes.
- [iOS connection](./ios-connection.md) signed in as `verifier` against this stack.
- Everyday Account is open (seeded).
- Use payee `Capture Toast Verify` so the row is unique.

- **Open blank.** Tap the tab-row plus `Add Transaction`. Sheet title `Add Transaction`. Leading `Cancel`. Direction `Outflow` selected. Amount shows a minus zero in the plan currency. Detail placeholders `Choose Payee`, `Choose Category`, `Choose Account` unless an account is already seeded (last-used / visible register). Glass keypad is up. Trailing `Save` is hidden.
- **Seeded account.** If Account already reads `Everyday Account`, leave it. If it is `Choose Account`, choose `Everyday Account`.
- **Fill amount.** Keypad digits for `5.40`. Payee `Capture Toast Verify` (optional for `canSave`, required for this unique HTTP check). Category may stay `Choose Category` or `Dining Out`.
- **Save.** Dismiss keypad (`done` / `next` / `save` on the keypad, or tap outside). Trailing glass `Save` appears and is enabled. Choose `Save`. Toast like `Saved {amount} — Capture Toast Verify`. Sheet dismisses. Accounts (or the register you came from) is back.
- **Register check.** Open `Everyday Account`. Today’s row `Capture Toast Verify` with outflow `5.40`.
- **HTTP match.** `control-howmuch http GET "/v1/plans/local-plan/transactions?since_date={today}&until_date={today}"` includes `payee_name` `Capture Toast Verify`, `account_id` `acct-everyday`, `amount` `-5400`.
- **Duplicate.** Long-press that row. Choose `Duplicate for Today`. Title `Add Transaction`. Amount `5.40`, keypad **hidden**. Payee still `Capture Toast Verify`. Date is today. Do not Save; choose `Cancel`.
- **Quick Action.** Close HowMuch to the home screen. Long-press the icon. Choose `Add Expense`. Blank Add Transaction (amount 0, keypad up). Cancel.
- **Proof.** Screenshot the open blank sheet with keypad (`artifacts/ios-capture/blank.png`), the saved Everyday Account row (`artifacts/ios-capture/saved.png`), and Duplicate with keypad hidden (`artifacts/ios-capture/duplicate.png`). Keep the HTTP JSON (`artifacts/ios-capture/transaction.json`).

## Gotchas

- Web `/add` is not this sheet. Do not mark iOS capture verified from the browser.
- Payee is optional. Amount 0 leaves Save disabled. Do not type a minus in the amount; Outflow owns the sign.
- Duplicate excludes splits. A split source row is the wrong fixture.
- Quick Action type is `sg.soon.howmuch.add-expense`, user title **Add Expense**. After #98 it must not depend on a notification hop; cold launch still opens the sheet.
- Opening capture while Connection / Settings / an editor is up waits until that sheet dismisses (after #98). Do not call a dropped request a pass.
- Title stays **Add Transaction**, never “Add expense”. Save stays **Save**, not `Save $5.00`.
- Offline Save can toast **Saved offline** and show an Accounts outbox card. That still counts as queued; HTTP may be empty until Sync Now. For this recipe, keep the API up so the row lands.
