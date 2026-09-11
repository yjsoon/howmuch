# iOS intake compose

Typed intake is a text field on the existing Add Transaction sheet. You type or paste a spend and hit Return. The form below is the review. `N == 1` stays on this sheet. No chat, no custom mic in v1. Spec: `docs/frontend/intake-ui.md`. Issues [#99](https://github.com/yjsoon/howmuch/issues/99), [#102](https://github.com/yjsoon/howmuch/issues/102).

## Sub-features

- `compose-present` shows a 48pt text field above the amount header on Add Transaction, not on Edit.
- `compose-placeholder` placeholder is data-driven (plan currency, a real category, seeded account), not `$5 of food on DBS`. No helper caption under the field.
- `compose-focus` focusing compose shows system QWERTY, hides the amount keypad, and hides trailing Save.
- `compose-amount-focus` tapping the amount resigns compose, shows the keypad, hides Save (as today).
- `compose-parse-n1` Return on a full sentence prefills amount, category, and unique account; compose keeps the text; keypad hidden when amount > 0; Save enabled when `canSave`.
- `compose-paste` paste into the field is the same path as typing (parse on Return, not on every keystroke).
- `compose-ambiguous` two matching accounts: Account stays `Choose Account`, ochre footnote `Which account?`, capsules without a chevron, Save disabled until a chip or picker.
- `compose-no-amount` Return with no amount shows the keypad, primary `done`.
- `compose-ai-off` Apple Intelligence off: compose gone, no gap, keypad path identical to [iOS capture](./ios-capture.md).
- `compose-downloading` `.modelNotReady` does **not** hide compose.
- `compose-no-post` nothing hits the outbox until Save.

## How to get to it (user POV)

- Tap the tab-row **Add Transactions** plus. Type in the compose field. Return.
- Paste a sentence into the same field, then Return.
- System-keyboard dictation into the same field (optional; not a custom mic).

Skip this file if the compose field is not on the sheet. Report the missing handle and issue #99. Do not drive `docs/frontend/intake-ui.html`.

## Driving it with control-howmuch

Preconditions:

- `control-howmuch doctor` passes.
- [iOS connection](./ios-connection.md) signed in.
- Compose field exists on Add Transaction (`!isEditing`).
- Use payee `Intake Toast Verify` when you need a unique saved row.
- Stub parse (#99) is enough for `compose-parse-n1` if it fills from a known sentence. Real `SlipReader` (#102) is required for live category/account matching beyond the stub.

- **Open.** Tap the tab-row plus `Add Transactions`. Title `Add Transaction`. First card is a white text field. No mic button. No caption “Type a spend”. Placeholder looks like `{n} of {Category} on {Account}` using live names (Groceries / Everyday Account are seeded), not a hardcoded DBS string.
- **Focus compose.** Tap the field. System keyboard. Amount keypad **hidden**. Trailing `Save` **hidden**. Amount header and Payee/Category/Account stay on screen, unchanged until Return.
- **Amount fight.** Tap the amount. Compose resigns. Keypad shown. Save hidden. Tap compose again. Keypad hidden, QWERTY back, Save hidden. Exactly one of {QWERTY, keypad}.
- **Parse N==1.** Type a sentence with amount 5, category Groceries, account Everyday Account (or the placeholder sentence). Return. Amount header shows 5.00 outflow. Category `Groceries`. Account `Everyday Account`. Compose still shows the sentence. Keypad hidden. `Save` visible and enabled. No “Looks right?” caption. No chat bubble.
- **Ambiguous.** Type a spend whose account hint matches more than one live account, or a stub that leaves account empty. Account row stays `Choose Account`. Footnote `Which account?` in uncategorised ochre (not red, not first-person). If two or three matches, capsules under that row, no chevron. `Save` disabled. Tap a chip: footnote/chips vanish, Account fills, Save enables.
- **No amount.** Type `coffee on Everyday Account` with no figure. Return. Keypad appears. Primary key `done`.
- **Paste.** Cancel. Open capture again. Paste the same full sentence. Return. Same prefill as typing.
- **Save still required.** After a successful parse, do **not** expect a POST yet. `control-howmuch http GET "/v1/plans/local-plan/transactions?since_date={today}&until_date={today}"` has no new intake row. Choose `Save`. Then HTTP includes the row (`amount` `-5000` for a 5.00 outflow if you used 5; match whatever you typed). Register on Everyday Account shows it.
- **AI off.** In Simulator Settings, turn Apple Intelligence off (or use a destination where the model is unavailable). Reopen capture. Compose is absent with no leftover gap. Keypad path matches [iOS capture](./ios-capture.md). If you cannot toggle AI, skip only `compose-ai-off`.
- **Downloading.** Do not hide compose just because the model is still downloading. If you cannot observe `.modelNotReady`, skip only `compose-downloading`.
- **Proof.** Screenshot idle compose (`artifacts/ios-intake-compose/idle.png`), focused QWERTY with Save hidden (`artifacts/ios-intake-compose/typing.png`), parsed form (`artifacts/ios-intake-compose/parsed.png`), ambiguous ochre (`artifacts/ios-intake-compose/ambiguous.png`). After Save, HTTP JSON (`artifacts/ios-intake-compose/transaction.json`) and register row (`artifacts/ios-intake-compose/register.png`).

## Gotchas

- Parse on Return only. Typing each letter must not flicker the form.
- Payee may stay `Choose Payee`. That does not block Save.
- Nickname “card x” that matches two cards must stay empty. A silent pick is a fail.
- Edit (register row → Edit) title is `Transaction`. Compose is absent there.
- Shortcuts and Duplicate land on this sheet **without** compose text (see [iOS App Intents](./ios-app-intents.md)). Do not expect parse chips on those paths.
- Custom mic, sparkles, or “HowMuch: I found…” fail the recipe even if parse works.
- Fail closed: no Worker `/parse`. `control-howmuch http GET /parse` must 404.
