# spending-breakdown proof

- Feature: `spending-breakdown`
- Entry points used: first-owner setup form at `{web_url}`, then Primary navigation `Spending breakdown`, then Date range `All`
- Instance: `http://127.0.0.1:42991` (control-howmuch run `20260829T002305-3709`)
- Action: created `verifier`, opened `/spending` on This month (August 2026), then chose All
- UI result: This month `$0.00` / "No spending in this range."; All `$3,292.30`, largest line Utilities
- Side effect: `report.json` from `GET /api/reports/spending-breakdown?plan_id=local-plan&from=2026-03-01&to=2026-05-31` (`data.total` 3292300)
