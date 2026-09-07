# iOS Rewards import

Rewards import takes a Rewards Tracker for YNAB settings export and stores that plan's cards, rules, and tag mappings. It lives under Connection settings, not in the tab bar. Cached YNAB-shaped rows in older dumps are upserted by their original IDs. Running the same file again updates those rows instead of duplicating them.

## Sub-features

- `ios-rewards-import-open` opens the screen from Connection settings → **Rewards import**, and from the empty Rewards tab button.
- `ios-rewards-import-empty` shows `No Rewards Tracker cards stored yet.` on a fresh verify instance.
- `ios-rewards-import-file` accepts `fixtures/rewards-tracker-export.json`. `Import export` stays disabled until a payload is chosen.
- `ios-rewards-import-invalid` on a non-JSON file shows `That file is not valid JSON. Export settings from Rewards Tracker, then choose the .json file.`
- `ios-rewards-import-run` imports the official export and lists Travel Card.
- `ios-rewards-import-replay` imports that file again and keeps a single Travel Card with the same counts.

## How to get to it (user POV)

- On Accounts, Rewards, or Reflect, choose **Connection settings** (ellipsis). When signed in, choose **Rewards import** under Tools.
- On an empty Rewards tab, choose **Rewards import**.

## Driving it with control-howmuch

Preconditions:

- `control-howmuch doctor` passes.
- [iOS connection](./ios-connection.md) signed in as `verifier` against this stack.
- Use the repo file `fixtures/rewards-tracker-export.json`. Do not invent a different export.
- Xcode Simulator is running HowMuch (`sg.soon.howmuch`). If Simulator is missing, skip this whole file.

- **Open page.** Connection settings → `Rewards import`. Navigation title is `Rewards import`. Empty copy is `No Rewards Tracker cards stored yet.` The tab bar has no `Rewards import` item.
- **Choose file.** Choose `Choose export`. Pick `fixtures/rewards-tracker-export.json`. Status is `Selected rewards-tracker-export.json`. `Import export` is enabled.
- **Import.** Choose `Import export`. The button reads `Importing…`, then `Imported this session` shows Cards `1`, Tag mappings `2`, Accounts upserted `1`, Transactions imported `0`. Stored cards lists `Travel Card` with `DBS · miles`.
- **Replay.** Choose the same file again. Choose `Import export`. Cards stays `1`. Stored cards still has one `Travel Card` row.
- **HTTP match.** `control-howmuch http GET /api/import/rewards-tracker?plan_id=local-plan` returns one card `card-travel` linked to `acct-credit`. `control-howmuch http GET /v1/plans/local-plan/accounts` still has one Travel Card. Do not POST the import from `control-howmuch http` and call the screen verified.
- **Proof.** Screenshot the empty screen (`artifacts/ios-rewards-import/empty.png`), the counts after the first import (`artifacts/ios-rewards-import/imported.png`), and save the GET snapshot JSON (`artifacts/ios-rewards-import/snapshot.json`).

## Gotchas

- Official Settings exports from Rewards Tracker are the Cloud Sync portable payload. They do not include cached transactions, so Transactions imported stays `0`.
- A fat localStorage dump with `cachedData.dashboardTransactions` will upsert those YNAB-shaped rows on `/v1`. That is a different file, not this recipe.
- This screen does not start YNAB OAuth. A file that is not JSON keeps `Import export` disabled after the error.
- Simulator file picking needs the fixture on the simulator. Copy `fixtures/rewards-tracker-export.json` into the simulator before driving, or skip with that reason.
