# iOS intake review list

When the reader returns more than one draft, confirmation is a register-shaped list, not a chat and not N copies of Add Transaction. Two spends in one typed sentence are enough; a screenshot is not required. Spec: `docs/frontend/intake-ui.md` §8. Issue [#103](https://github.com/yjsoon/howmuch/issues/103).

## Sub-features

- `list-open` two spends in one compose Return open a sheet titled **{N} Transactions**.
- `list-include` leading include controls; all on by default; unchecked rows dim and drop from the count.
- `list-no-status` no trailing cleared/approve circle on these rows.
- `list-row-edit` tapping a row opens `TransactionFormView` for that draft (keypad hidden if amount > 0).
- `list-uncategorised` Uncategorised footnote is ochre, not red. Amounts use register colour (ink for outflows).
- `list-repair` muted repair field, placeholder `everything from Cold Storage is groceries`, Return mutates the list, no send arrow.
- `list-add` trailing glass `Add {n} to {account}` disabled at 0 included or any included row unsaveable.
- `list-commit` Add writes through one outbox save; Cancel posts nothing.
- `list-not-chat` no thread, no typing indicator, no “I found four spends”.

## How to get to it (user POV)

- On Add Transaction, type two spends in one sentence (e.g. `5 groceries on Everyday and 3.20 dining on Everyday`). Return.
- Later: a multi-row paste, share, or screenshot uses this same sheet. Density follows row count, not source.

Skip if Return with two spends stays on Add Transaction or opens a chat. Report issue #103.

## Driving it with control-howmuch

Preconditions:

- `control-howmuch doctor` passes.
- [iOS connection](./ios-connection.md) signed in.
- [iOS intake compose](./ios-intake-compose.md) compose field exists.
- Reader (stub or `SlipReader`) can return two drafts from one string.
- Unique payees: leave payee empty or use names you can grep, e.g. keep amounts `7.10` and `2.30` so HTTP is identifiable.

- **Open list.** Compose two spends in one sentence. Return. Title `{2} Transactions` (or the live N). Leading `Cancel`. No 40pt amount header.
- **Chrome.** Source strip `Typed · just now` (or equivalent). Each row: leading include on, payee semibold, category footnote, tabular amount. No trailing status circle.
- **Drop one.** Uncheck one include. That row dims. Trailing control count drops (`Add 1 to Everyday Account` if the remaining row has that account).
- **Edit row.** Re-include. Tap a row. Add Transaction / form for that draft. Amount keypad hidden if amount > 0. Cancel back to the list. Edits you Save on the child form stick on the list.
- **Repair.** Repair field at footnote density. Type `everything from Cold Storage is groceries` only if a Cold Storage payee exists in the list; otherwise type a sentence that assigns Groceries to an Uncategorised row. Return. That row’s category footnote updates. No chat transcript.
- **Add.** Trailing glass `Add {n} to {account}` enabled. Choose it. List dismisses. Toast/success. Everyday Account register shows both included rows for today.
- **HTTP match.** `control-howmuch http GET "/v1/plans/local-plan/transactions?since_date={today}&until_date={today}"` includes both amounts (milliunits, negative for outflows). Unchecked rows are absent.
- **Cancel path.** Repeat with two new amounts. Choose `Cancel`. HTTP does not gain those amounts.
- **Proof.** Screenshot the list (`artifacts/ios-intake-review-list/list.png`), one dropped row (`artifacts/ios-intake-review-list/dropped.png`), and the register after Add (`artifacts/ios-intake-review-list/register.png`). Keep HTTP JSON (`artifacts/ios-intake-review-list/transactions.json`).

## Gotchas

- Title is a noun: **2 Transactions**, not “Found 2”.
- Trailing control is glass prominent like Save, not a full-width solid pill — but the **label** is `Add {n} to {account}`. Live `n`.
- Uncategorised ochre is `Theme.uncategorised`. Outflow red is only for errors.
- Add must not POST `{ "transactions": [...] }` from the sheet as a special import route. Side effect is still ordinary `/v1/plans/local-plan/transactions` rows with `import_id`. A crash after Add before ACK must not double-post (same as single create).
- One-row parse must **not** open this list. That is [iOS intake compose](./ios-intake-compose.md).
