# Rewards import

Rewards import takes a Rewards Tracker for YNAB settings export and stores that plan's cards, rules, and tag mappings. Cached YNAB-shaped rows in older dumps are upserted by their original IDs. Running the same file again updates those rows instead of duplicating them.

## Sub-features

- `rewards-open` opens the page from **Rewards import** and from `/import/rewards`.
- `rewards-empty` shows no stored cards on a fresh verify instance.
- `rewards-import` accepts `fixtures/rewards-tracker-export.json` and lists Travel Card.
- `rewards-replay` imports that file again and keeps a single Travel Card with the same counts.

## How to get to it (user POV)

- Choose **Rewards import** in Primary navigation.
- Open `{web_url}/import/rewards`.

## Driving it with control-howmuch

Preconditions:

- `control-howmuch doctor` passes.
- Owner `verifier` is signed in.
- Use the repo file `fixtures/rewards-tracker-export.json`. Do not invent a different export.

- **Open page.** Choose `Rewards import`. Title is `Rewards import · HowMuch`. Heading is `Rewards import`. Empty copy is `No Rewards Tracker cards stored yet.`
- **Choose file.** Field `Rewards Tracker export` accepts the JSON file. After choosing `fixtures/rewards-tracker-export.json`, status is `Selected rewards-tracker-export.json`. `Import export` is enabled.
- **Import.** Choose `Import export`. The button reads `Importing…`, then `Imported this session` shows Cards `1`, Tag mappings `2`, Accounts upserted `1`, Transactions imported `0`. Stored cards lists `Travel Card` with `DBS · miles`.
- **Replay.** Choose the same file again. Choose `Import export`. Cards stays `1`. Stored cards still has one `Travel Card` row.
- **HTTP match.** `control-howmuch http GET /api/import/rewards-tracker?plan_id=local-plan` returns one card `card-travel` linked to `acct-credit`. `control-howmuch http GET /v1/plans/local-plan/accounts` still has one Travel Card. Do not POST the import from `control-howmuch http` and call the page verified.
- **Proof.** Screenshot the empty page (`artifacts/rewards-tracker-import/empty.png`), the counts after the first import (`artifacts/rewards-tracker-import/imported.png`), and save the GET snapshot JSON (`artifacts/rewards-tracker-import/snapshot.json`).

## Gotchas

- Official Settings exports from Rewards Tracker are the Cloud Sync portable payload. They do not include cached transactions, so Transactions imported stays `0`.
- A fat localStorage dump with `cachedData.dashboardTransactions` will upsert those YNAB-shaped rows on `/v1`. That is a different file, not this recipe.
- Viewport ≤720px hides the sidebar. Open **Open menu** before **Rewards import**.
- This page does not start YNAB OAuth. A file that is not JSON keeps `Import export` disabled after the error.
