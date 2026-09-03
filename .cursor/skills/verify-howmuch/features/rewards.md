# Rewards

Rewards shows imported Rewards Tracker cards against the HowMuch ledger. It is a Reflect report. There is no live YNAB connection.

## Sub-features

- `rewards-nav` opens the report from Primary navigation and from `/rewards`.
- `rewards-empty-import` on a fresh verify instance, with no export imported, points at Rewards import.
- `rewards-import-then-view` after importing `fixtures/rewards-tracker-export.json` shows Travel Card on the All range.
- `rewards-flags` lists Dining and Online flag rows on Travel Card.
- `rewards-group` switches Group to Payee and lists Candlenut.

## How to get to it (user POV)

- Choose **Rewards** in Primary navigation.
- Open `{web_url}/rewards`.
- Keep the current query string when moving from another Reflect tab.

## Driving it with control-howmuch

Preconditions:

- `control-howmuch doctor` passes.
- Owner `verifier` is signed in.
- Demo ledger still contains Travel Card spends (Grab, Scoot, MUJI, Candlenut).

- **Open empty.** Open `{web_url}/rewards`. Title is `Rewards · HowMuch`. Heading is `Rewards`. Active preset is `All`. Status is `No reward cards in this range.` with a link to `Settings → Rewards import`.
- **Import.** Choose `Settings`, then `Rewards import`. Choose `fixtures/rewards-tracker-export.json`. Choose `Import export`. Stored cards lists `Travel Card`.
- **Open filled.** Choose `Rewards`. Title is `Rewards · HowMuch`. A Miles tile named `Travel Card` is visible. Qualifying spend is greater than `$0.00`. Group rail includes `Flag`, `Payee`, `Category`, `Memo`.
- **Group by payee.** Choose `Payee`. The groups table includes `Candlenut`.
- **HTTP match.** `control-howmuch http GET "/api/reports/rewards?plan_id=local-plan&group=payee"` returns `data.cards` with `card-travel` and `data.groups` containing Candlenut. Do not POST the import from `control-howmuch http` and call the page verified.
- **Proof.** Screenshot the empty page (`artifacts/rewards/empty.png`), the Travel Card tile after import (`artifacts/rewards/travel-card.png`), the payee groups table (`artifacts/rewards/group-payee.png`), and save the GET JSON (`artifacts/rewards/report.json`).

## Gotchas

- Demo rows are dated 2026-03-01 through 2026-05-24. `This month` is empty unless today falls in that span. Stay on `All`.
- The dashboard reads the HowMuch ledger, not a second YNAB sync. Import the settings export first.
- Viewport ≤720px hides the sidebar. Open **Open menu** before **Rewards**.
