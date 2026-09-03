# iOS App Intents

Shortcuts adds a spend by opening HowMuch with the existing Add Transaction sheet already filled. Nothing is saved until the user taps **Save**. Structured parameters only in v1. Spec: `docs/frontend/app-intents.md`. Issues [#98](https://github.com/yjsoon/howmuch/issues/98), [#100](https://github.com/yjsoon/howmuch/issues/100), [#101](https://github.com/yjsoon/howmuch/issues/101). Later text/image: [#105](https://github.com/yjsoon/howmuch/issues/105).

## Sub-features

- `intent-listed` Shortcuts shows **Add Transaction** with amount, direction, account, payee, category, date, flag, memo, cleared.
- `intent-names` account / payee / category pickers show live HowMuch Demo names (Everyday Account, Groceries, FairPrice Finest), not raw ids.
- `intent-prefill` a filled shortcut opens Add Transaction, keypad hidden iff amount > 0, fields match the parameters.
- `intent-like-duplicate` Shortcuts landing has **no** compose text and **no** parse chips. Missing account is `Choose Account`.
- `intent-bare` phrase **Add a transaction in HowMuch** opens a blank sheet, same as +.
- `intent-cansave` amount + account only is enough for Save (payee optional).
- `intent-no-autosave` after `perform()`, outbox/HTTP have no new row until Save.
- `intent-stale` a shortcut whose account/payee/category was deleted leaves that field on Choose …; no silent substitute.
- `intent-transfer` transfer payee drops category when both accounts are on-budget (same as Payee picker).
- `intent-signed-out` signed out: app opens Connection; no crash; no other plan’s picker names.
- `intent-text-image` later **Add from Text** / **Add from Image** write the inbox and follow the density rule. Skip until #105.

## How to get to it (user POV)

- Open **Shortcuts** on the Simulator. Add action **Add Transaction** from HowMuch, or run the App Shortcut **Add a transaction in HowMuch**.
- Fill amount `3.50`, payee `Shortcut Coffee Verify`, category `Dining Out`, account `Everyday Account`, direction Outflow. Run.
- HowMuch comes to the foreground on Add Transaction. Glance. Save.

Skip this file if Shortcuts has no HowMuch **Add Transaction** action. Report #101. Catalog (#100) must already have been written after a successful iOS refresh.

## Driving it with control-howmuch

Preconditions:

- `control-howmuch doctor` passes.
- [iOS connection](./ios-connection.md) signed in, then at least one Accounts refresh so IntentCatalog exists.
- [iOS capture](./ios-capture.md) still works (door #98).
- Use payee `Shortcut Coffee Verify`.
- Simulator Shortcuts app is available. If you cannot open Shortcuts, skip this file; do not invoke the intent via a hidden URL and call it the user path.

- **Pickers.** In Shortcuts, add **Add Transaction**. Account list includes `Everyday Account`, `Rainy Day Saver`, `Travel Card`. Category list includes `Groceries` and `Dining Out`. Payee search can find `FairPrice Finest` and Create “…” for a new name. Flag is labelled Flag, not “label”.
- **Bare phrase.** Run `Add a transaction in HowMuch` with no parameters. HowMuch shows blank Add Transaction (amount 0, keypad up), same as the plus tab. Cancel. HTTP unchanged.
- **Filled run.** Amount `3.50`, Direction Outflow, Account `Everyday Account`, Payee `Shortcut Coffee Verify` (Create if needed), Category `Dining Out`, Date today, Cleared off. Run. Sheet title `Add Transaction`. Amount `3.50`, keypad hidden. Account Everyday Account. Category Dining Out. **Compose field empty** (or absent of the shortcut sentence). No `Which account?` chips. `Save` enabled.
- **No autosave.** Before tapping Save: `control-howmuch http GET "/v1/plans/local-plan/transactions?since_date={today}&until_date={today}"` has no `Shortcut Coffee Verify`. HowMuch Accounts outbox is empty.
- **Save.** Choose `Save`. Toast `Saved … — Shortcut Coffee Verify`. Everyday Account register shows `3.50` outflow today. HTTP `payee_name` `Shortcut Coffee Verify`, `amount` `-3500`, `account_id` `acct-everyday`.
- **Signed out.** Connection → `Sign out / Use another account`. Run the filled shortcut again. Lands on Connection (or drops the draft and shows Connection). No Accounts ledger from another host. Copy along the lines of `Sign in to HowMuch, then run this shortcut again` is acceptable. Sign back in to `{api_url}` before the next recipe.
- **Text/image.** If **Add from Text** / **Add from Image** exist, a sentence uses the compose reader; an image shows `Reading…` then density. Nothing posts until confirm. If they do not exist, skip `intent-text-image`.
- **Proof.** Screenshot Shortcuts parameters (`artifacts/ios-app-intents/shortcuts.png`), the prefilled sheet before Save (`artifacts/ios-app-intents/sheet.png`), and the register row (`artifacts/ios-app-intents/register.png`). HTTP JSON (`artifacts/ios-app-intents/transaction.json`) from **before** Save (no row) and after Save (row present).

## Gotchas

- Never auto-save from Shortcuts. A green Shortcuts checkmark with no HowMuch Save tap is a fail if HTTP gained a row.
- Do not grow **Add Transaction** with a free-text or file parameter that skips the reader. That is a different intent (#105).
- Negative amount in Shortcuts must not flip direction. More than three fractional digits should error in Shortcuts, not round.
- Stale entity: delete is hard on the demo ledger. If you cannot delete, skip only `intent-stale`. Do not prove it by swapping in Travel Card.
- Signed-out pickers are empty. `perform` still opens the app.
- Duplicate, plus, and Quick Action must still match [iOS capture](./ios-capture.md) after the intent ships.
