# Scheduled transactions

Scheduled is the upcoming-recurring list. The demo seed has none. The user adds a schedule, sees it grouped by next date, and can enter it into the register.

## Sub-features

- `scheduled-open` opens the page from **Scheduled** and from `/scheduled`.
- `scheduled-empty` shows **No active schedules.** on a fresh demo.
- `scheduled-add` creates a monthly outflow and lists it.
- `scheduled-enter` materialises the next occurrence onto the register.

## How to get to it (user POV)

- Choose **Scheduled** in Primary navigation.
- Open `{web_url}/scheduled`.
- On a register, expand **Scheduled** (disclosure only; full edit lives here). It appears on Ledger as well as a single-account register, collapsed by default, and holds recurrences plus posted future-dated rows.

## Driving it with control-howmuch

Preconditions:

- `control-howmuch doctor` passes.
- Owner `verifier` is signed in.
- Everyday Account is seeded.
- Use memo `Verify schedule` so the row is unique.

- **Open page.** Choose `Scheduled`. Title is `Scheduled transactions · Halation`. Heading is `Scheduled transactions`. Region `Schedule summary` shows `Active schedules` `0` and `Next due` `—`. Status title is `No active schedules.`
- **Open editor.** Choose `Add schedule`. Section title is `Add scheduled transaction`.
- **Fill monthly outflow.** Account `Everyday Account`. Amount `-18.50`. First date and Next date `Today`. Repeat `Monthly`. Payee `FairPrice Finest` if listed, otherwise leave `No payee`. Memo `Verify schedule`. Choose the submit `Add schedule`.
- **Listed.** `Active schedules` is `1`. `Next due` is today. A table row shows memo `Verify schedule` and amount `-18.50`.
- **Enter now.** Choose `Enter FairPrice Finest now`. Confirm heading `Enter scheduled transaction now?`. Leave Register date as today. Choose `Enter now`. Status mentions the entered date. `control-howmuch http GET "/v1/plans/local-plan/transactions?since_date={today}&until_date={today}"` includes amount `-18500` and memo `Verify schedule`.
- **Proof.** Screenshot the empty state (`artifacts/scheduled-transactions/empty.png`) and the listed schedule (`artifacts/scheduled-transactions/created.png`). Keep the HTTP JSON (`artifacts/scheduled-transactions/entered.json`).

## Gotchas

- Demo ledger has no schedules. Empty is correct until you add one.
- Amount is signed. Minus is outflow. Do not type `18.50` and expect a spend.
- Payee is a select of existing payees, not a free-text field. Memo is the stable handle when you leave payee empty.
- Register **Scheduled** is a read-only disclosure on Ledger and on one account. Recurrences and posted future-dated rows live inside it. Creating and editing happen on `/scheduled`.
- A default **2M** window ends today. Posted futures still load into **Scheduled**; they do not sit in the main table.
- **Enter now** writes a real register row and advances `date_next`. Do not treat the schedule list itself as the ledger proof.
