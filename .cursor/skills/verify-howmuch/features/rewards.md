# Rewards

Rewards shows stored reward cards against the HowMuch ledger as a board of card faces ("Exposure"). There is no live YNAB connection. The board opens in **Card periods** mode, as of today (Singapore). Each card uses its own billing or reward period. **Historical range** is the other mode. **Add card** opens the native editor. Import and export live under Settings, and are also linked from **Arrange**.

## Sub-features

- `rewards-nav` opens the board from **Rewards** in Primary navigation and from `/rewards`.
- `rewards-add-card` shows **Add card** in the hero, top right, and opens `/rewards/new`.
- `rewards-empty-import` on a fresh verify instance, with no export imported, points at Rewards import and **Add card** for an existing HowMuch card.
- `rewards-import-then-view` after importing `fixtures/rewards-tracker-export.json` shows the Travel Card face in the Miles group.
- `rewards-historical-all` keeps **Historical range** selected when the rail's **All** preset clears the dates, and scores every card across all history ([#278](https://github.com/yjsoon/howmuch/issues/278)).
- `rewards-as-of` steps the as-of date with **Previous day** and **Next day**, or sets it with the **As of** date input. **Next day** and **Today** are disabled at today. A future date clamps to today.
- `rewards-flags` lists Dining and Online flag rows on Travel Card.
- `rewards-group` switches **Report grouping** (in the breakdown heading) to Payee and lists Candlenut.
- `rewards-accounts` scopes the board with the **Accounts** multi-select. An account with no reward card shows "None of the selected accounts has a reward card." with **Show all accounts**.
- `rewards-arrange` sets Order (Manual, Name, Reward value, Spend), **Group by type** and **Show hidden (N)** from the **Arrange** popover. **All cards** and **Featured** sit beside it.
- `rewards-card-menu` opens **Actions for {card}** (⋯), which has Edit card, View transactions, Hide or Unhide ("On this device") and **Hide until next period** ("Returns {date}").
- `rewards-batch` uses **Select**, then the **Batch card edits** bar: **Select visible**, **Batch field**, **Batch value**, **Apply to selected**, then **Done**.

## How to get to it (user POV)

- Choose **Rewards** in Primary navigation.
- Open `{web_url}/rewards`.
- Choose **Add card** to open `/rewards/new`. Card edit lives in [Rewards card edit](./rewards-card-edit.md).
- Keep the current query string when moving from a report page.

## Driving it with control-howmuch

Preconditions:

- `control-howmuch doctor` passes.
- Owner `verifier` is signed in.
- Demo ledger still contains Travel Card spends (Grab, Scoot, MUJI, Candlenut).

- **Open empty.** Open `{web_url}/rewards`. Title is `Rewards · Halation`. Heading is `Rewards`. **Card periods** is pressed and the date face reads today. **Add card** is present. Status is `No reward cards in this range.`, with links to `Settings → Rewards import` and **Add card** to score one of your Halation cards.
- **Import.** Choose `Settings`, then `Rewards import`. Choose `fixtures/rewards-tracker-export.json`. Choose `Import export`. Stored cards lists `Travel Card`.
- **Open filled.** Choose `Rewards`. Title is `Rewards · Halation`. A Miles face named `Travel Card` is visible. Set **As of** to `2026-05-24`, or open `{web_url}/rewards?to=2026-05-24`. The date face reads `24 May 2026` in italics, and **Today** is enabled. Qualifying spend is greater than `$0.00`. The slip's headline reads `Minimum met`, with the deadline `Resets in 8 days` and the basis line `$315.50 / $200.00`. Open **Targets, periods and tiers** (the old "Periods and tiers" footer): the meter there reads `Full-period minimum met`. The face is the Sun Arc (docs/frontend/rewards-exposure-card.md): each card carries `data-stage` (gate, climb, rest, capped, calm, failed) and inline `--rw-h` and `--rw-v`; the marker is the `.rw-mk` line, drawn only in the gate stage, at `--rw-h` of the face width. **Report grouping** includes `Flag`, `Payee`, `Category`, `Memo`.
- **Historical range, All.** Choose **Historical range**, then **All** in the rail's **Date range** group. **Historical range** stays pressed, the URL carries `mode=range&range=all`, and the hero scope reads `All time · All accounts`. Qualifying spend is `$830.80`, every Travel Card spend in the demo ledger, and the report `period` starts at the first one (`2026-03-11:{today}`). Choose **Card periods**: the hero reads `Card periods as of {today}` and `mode` leaves the URL. `control-howmuch http GET "/api/reports/rewards?plan_id=local-plan&mode=range"` returns the same totals. Scripted run: `.amp/in/artifacts/rewards-all-range/rewards-all-range.mjs`.
- **Group by payee.** In **Report grouping**, choose `Payee`. The heading reads `By payee`, and the groups table includes `Candlenut`.
- **Batch edit.** Choose **Select** (it reads **Done** while on). Choose **Select visible**. Set **Batch field** to `Base earning rate` and **Batch value** to `1.5`. Choose **Apply to selected**. The updated face pulses once, and the count returns to `0 selected`.
- **Hide until next period.** Back on today, open **Actions for Travel Card** and choose **Hide until next period**. "All cards are hidden." appears. Choose **Show hidden cards**. The face carries the badge `Back {date}`. Open the menu again and choose **Unhide**.
- **HTTP match.** `control-howmuch http GET "/api/reports/rewards?plan_id=local-plan&group=payee&to=2026-05-24"` returns `data.cards` with `card-travel` and `data.groups` containing Candlenut. After the batch edit, the same read shows `card.earningRate` set to `1.5`. Do not POST the import from `control-howmuch http` and call the page verified.
- **Proof.** Screenshot these into `.amp/in/artifacts/rewards/`: the empty page (`empty.png`), the Travel Card face as of 24 May 2026 (`travel-card.png`), the payee groups table (`group-payee.png`), select mode with the bulk bar (`select.png`) and an open card menu (`card-menu.png`). Save the GET JSON as `report.json`. Capture open menus and popovers at viewport size: full-page captures resize the page while the drop-in plays.

## Gotchas

- Demo rows are dated 2026-03-01 through 2026-05-24. As of today the card periods are empty, so qualifying spend is `$0.00` and the groups table reads "No qualifying transactions". Step back to 24 May 2026 before you check figures, or use **Historical range** on those months.
- In Card periods mode there is no filter rail. The rail, with its presets and Group, appears only in **Historical range**.
- Display preferences (order, grouping, hidden cards, collapsed groups) live in `localStorage["howmuch:rewards:local-plan"]` on this device. Clear that key to reset the board between runs.
- Arrange, hide, move and group-collapse changes run a short view transition. A test that reads a checkbox or radio straight after clicking may see the old state for one frame, so click, then assert.
- The dashboard reads the HowMuch ledger, not a second YNAB sync. Import the settings export first.
- Viewport ≤720px hides the sidebar. Open **Open menu** before **Rewards**. Card menus and **Arrange** open as bottom sheets, and the batch bar is pinned to the bottom of the screen.
