# Rewards: Historical range "All" (#278)

## Revisions

- `before/`: base `d35b664` (unchanged trunk).
- `after/`: `d35b664` plus the fix on branch `claude/project-thread-myu6lq`.

## Fixture and setup

Disposable stack per run: `control-howmuch launch` (seeds `fixtures/demo-ledger.json` into a private SQLite file), fresh each time. The script completes first-owner setup in the browser, imports `fixtures/rewards-tracker-export.json` through Settings → Rewards import, then drives `/rewards`. No production data.

## Commands

```sh
export PATH="$PWD/.cursor/skills/verify-howmuch/bin:$PATH"
control-howmuch launch && control-howmuch doctor
# WEB and DB from `control-howmuch state` (web_url, db_path)
node .amp/in/artifacts/rewards-all-range/rewards-all-range.mjs "$WEB" "$PWD" <out_dir> "$DB"
control-howmuch cleanup
```

The script needs `playwright` (run here with 1.56.1 and the preinstalled Chromium) and Node 22 for `node:sqlite`.

## Steps and expected outcomes

At 1440px and 390px:

1. Open `/rewards`, choose **Historical range**, then **All** in the **Date range** group.
2. Expect **Historical range** pressed, **All** pressed, hero scope `All time · All accounts`, URL `mode=range&range=all`.
3. Expect the report's `period` to start at the first Travel Card spend and `totals.spend` to equal the sum of every Travel Card spend. Both expected values are read straight from the ledger SQLite, not from the report code (`2026-03-11`, `830.8`).

Then choose **Card periods** and expect `Card periods as of {today}` with `mode` gone from the URL.

## Observed

- `before/results.json`: 14 of 16 checks fail. All drops back to Card periods as of today, the rail disappears, spend is `$0.00`. This reproduces the issue.
- `after/results.json`: 16 of 16 pass. Spend `$830.80`, value `$44.83`, 2,989 miles, period `2026-03-11:2026-10-10`; the page requests `/api/reports/rewards?plan_id=local-plan&mode=range`.

Screenshots: `historical-all-1440.png`, `historical-all-390.png`, `card-periods-after.png` in each folder; report excerpts in the matching `.json` files.
