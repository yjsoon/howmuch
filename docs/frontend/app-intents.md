# App Intents — Shortcuts capture

Design only. No Swift in this slice. Paired with [#87](https://github.com/yjsoon/howmuch/issues/87) intake (compose, share, reader) and the capture UI in [`intake-ui.md`](./intake-ui.md).

**v1 is structured.** Shortcuts exposes amount, payee, category, flag, memo, account, date, direction, cleared. The user lands on the existing **Add Transaction** sheet, already filled. They tap Save. Nothing is recorded until then.

**Later** is unstructured: a second intent (or the share sheet) hands text or an image to the same inbox + `SlipReader` + density rule. Not a third confirmation UI. Not Foundation Models inside the intent process.

## Shared door

Today four doors already fight:

| Door | What it does now |
| --- | --- |
| Tab + | `isShowingCapture = true` → `AddTransactionSheet` always seeds a **fresh** draft |
| Home-screen Quick Action | `QuickAction.pendingCapture` bool + notification → same blank sheet |
| Duplicate for Today | **Separate** `.sheet(item:)` with `TransactionFormView(draft:)` |
| Intake / share (planned) | Prefill `TransactionDraft`, or review list when `N > 1` |

The App Intent is a fifth door. Do not add a sixth sheet.

Replace the bool with one request:

```
enum CaptureRequest {
  case blank                          // +, Quick Action
  case draft(TransactionDraft)      // intent, Duplicate, intake N == 1
  case inbox                          // later: share / screenshot / text-or-image intent
}
```

One function: `AppModel.presentCapture(_ request: CaptureRequest)`.

- Stores the request, sets the capture sheet up, dismisses Settings first (today’s Quick Action behaviour).
- Cold launch: a small pending slot (same role as `QuickAction.pendingCapture`) because the intent/`UIApplicationShortcutItem` cannot see the `@State` `AppModel`.
- If the sheet is already up, **replace** the request. A second shortcut must not no-op.
- `AddTransactionSheet` seeds only `.blank`. `.draft` is handed to `TransactionFormView(draft:isEditing: false)` as Duplicate already does. Keypad stays down when amount > 0.
- `.inbox` is not a form. RootView claims `Inbox/` → reader → density rule (`N == 1` becomes `.draft`, `N > 1` is the review list).

`TransactionDraft` stays the only editable DTO. Do not invent `ProposedTransaction`.

## v1 intent

One intent, main target `sg.soon.howmuch`. Not a split “Add Expense” / “Add Income”.

| | |
| --- | --- |
| Type | `AddTransactionIntent` |
| Shortcuts title | **Add Transaction** |
| Description | **Opens HowMuch with a transaction ready to review and save. Nothing is saved until you tap Save.** |
| App Shortcut | “Add a transaction in HowMuch” |
| `openAppWhenRun` | `true` |
| `ForegroundContinuableIntent` | **No.** This intent always needs the app. Signed-out: open HowMuch onto the connection screen (already the cold-launch path). |

`perform()` builds a `TransactionDraft`, calls `presentCapture(.draft)`, returns no transaction value. It never calls `commit`, never POSTs, never fills the outbox.

### Parameters (all optional except as noted)

Shortcuts can expose any subset. A bare “Add a transaction in HowMuch” is today’s blank sheet. A daily coffee shortcut fills amount, payee, category, account.

| Shortcuts label | Type | Default | `TransactionDraft` |
| --- | --- | --- | --- |
| Amount | `Decimal` | omitted → `$0`, keypad up | `amountMagnitudeMilli` via `MoneyCodec.milliunits(from: Decimal)` (new overload, same overflow / 3-decimal guards as the string path). **Magnitude only.** Sign is discarded. Direction owns the sign. |
| Direction | `AppEnum` on `EntryDirection` | Outflow | `direction` |
| Account | `AccountEntity` | omitted → `seedIfNeeded` | `accountID` |
| Payee | `PayeeEntity` (`EntityStringQuery`) | omitted | matched: `payeeID` + name; transfer: `transferAccountID` and drop category (same as `PayeePicker`); unmatched search: synthetic **Create “…”** → `payeeName` only, `payeeID` nil |
| Category | `CategoryEntity` | omitted | `categoryID` |
| Date | `Date` (day) | today, local calendar | `date` |
| Flag | `AppEnum` on `FlagColour` | None | `flag` (user-facing “Flag”, not “label”) |
| Memo | `String` | omitted | `memo` |
| Cleared | `Bool` | false | `isCleared` |

No split lines in v1. No free-text ledger IDs. Amount `0` is allowed (sheet opens; `canSave` stays false until they type one). Negative Decimal does **not** flip direction.

Transfer payee + both accounts on-budget: nil `categoryID` even if the shortcut also sent a category (picker rule). Transfer to the selected account: drop the payee, leave a placeholder.

Stale entity IDs (renamed/deleted since the shortcut was saved): **drop that field**, leave the picker empty. Never silent-substitute another account.

## Entities and catalog

`AppModel` is `@State`. EntityQuery often runs with no scene. Do not read `@State` from the query.

`IntentCatalog` is a **projection** of the same `Account` / `Category` / `Payee` arrays `refreshReferenceData` already loaded. Written after a successful refresh. Wiped on sign-out. Keyed by connection fingerprint so a second plan cannot leak. v1 lives in Application Support. When `group.sg.soon.howmuch` lands for share, move the file there — same IDs, not a second ledger.

Filters match the pickers:

- Accounts: open only (`openAccounts`).
- Categories: not deleted; quiet groups last; group name as subtitle. Hidden bookkeeping excluded the same way `CategoryPickerView` does.
- Payees: not deleted; transfers included, subtitle **Transfer**; recents as suggestions if cheap.

Signed out / empty catalog: pickers empty. `perform` still opens the app. Copy: **Sign in to HowMuch, then run this shortcut again.**

## Later: text and image

Do **not** grow `AddTransactionIntent` with a `String`/`IntentFile` that bypasses the reader.

Thin intents (`Add from Text`, `Add from Image`) copy bytes into the #87 App Group inbox and `presentCapture(.inbox)`. Share extension already planned to do the same. Main app: claim → `SlipReader` → density rule. Intent process does not run Foundation Models.

v1 must not: shrink `CaptureRequest` to `TransactionDraft?` (no room for inbox / `N > 1`); return a saved `Transaction` from `perform`; parse in the intent.

## Reuse

| Need | Code |
| --- | --- |
| DTO | `TransactionDraft` |
| Prefill UI | `TransactionFormView(draft:isEditing:)` |
| Blank seed | `seedIfNeeded` |
| Milliunits | `MoneyCodec` + Decimal overload |
| Direction / flag | existing enums + thin `AppEnum` |
| Picker filters / transfer | extract predicates from `Pickers.swift` |
| Save | `AppModel.commit` from the sheet only |
| Cold-launch pending | generalise `QuickAction.pendingCapture` |

New files (when built): `Intents/AddTransactionIntent.swift`, entities + queries, `AppShortcutsProvider`, `IntentCatalog` store, `CaptureRequest` next to `AppModel`.

## Rejected

- Auto-save from Shortcuts.
- URL scheme as the only handoff (no entity pickers).
- Parse text/image in the intent process.
- Parallel proposed-transaction DTO.
- Separate expense/income intents.
- Intents extension target (needs App Group now; parse would leak there).

## Build order

1. `CaptureRequest` + `presentCapture`. Retarget tab +, Quick Action, Duplicate. Behaviour unchanged.
2. `AddTransactionSheet` accepts an incoming draft.
3. `IntentCatalog` written on refresh, wiped on sign-out.
4. Entities + queries. Confirm Shortcuts lists live names.
5. `AddTransactionIntent` → `presentCapture(.draft)`. Prove nothing hits the outbox until Save.
6. `AppShortcutsProvider`.
7. Later, after #87 inbox/reader: text and image intents.

## Acceptance (v1)

- [ ] Shortcuts shows **Add Transaction** with pickers for account, payee, category, flag, plus amount, direction, date, memo, cleared.
- [ ] Running it opens the existing Add Transaction sheet, prefilled. Save still goes through `commit`.
- [ ] A shortcut with only amount + account is enough for `canSave` after open (payee optional).
- [ ] Bare “Add a transaction in HowMuch” opens a blank sheet, same as +.
- [ ] Transfer payee follows the picker (category dropped when required).
- [ ] Stale or missing entity IDs leave the field empty.
- [ ] Signed out: app opens to connection; no crash; no other plan’s catalog.
- [ ] Duplicate, +, and Quick Action still work after the shared door lands.
