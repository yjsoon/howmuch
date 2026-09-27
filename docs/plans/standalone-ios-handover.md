# Standalone iOS: overnight handover (2026-09-26)

This covers branch `feat/standalone-ios`, rebased onto `main` at `07bd082`. Nothing has been pushed, tagged, deployed or migrated.

## What changed

| Commit | What |
|---|---|
| `795cf3c` refactor(api) | Removes the budgeting routes and code: `/months/**`, assignments, targets and month-activity rebuilds. Tables are kept, with no migration and no data touched. |
| `88e5bd9` feat(api) | Category and category-group management, allowed only on native plans. A YNAB-mirror plan such as yours returns 409. |
| `4dd52bd` feat(api) | `export_snapshot` / `import_snapshot`. Import is atomic, accepts only an empty plan and is capped at 8 MiB. |
| `1c53a82` docs | `standalone-ios.md` and `offline-writes.md`. |
| `8733777` refactor(ios) | Removes the Plan tab, its More-menu entry and the month API calls. |
| `4dd8008` build(ios) | The unchanged `apps/api` backend, bundled for JavaScriptCore (`bun run build:ios-engine` / `check:ios-engine`). |
| `4cd305f` feat(ios) | Local mode. First launch offers "Start on this iPhone" or "Connect to a server"; data lives in SQLite on the device. |
| `6d54e89` fix(api) | Snapshots now carry free-text payee names, with an all-columns round-trip test. |
| `906dac8` feat(ios) | Connect a local install to a server. An empty plan gets the device's data uploaded. A plan with data asks you to choose between the server and the iPhone; the two are never merged. The local database is kept as an archive you can export or switch back to. |
| `b849d80` fix(ios) | Capture opens from cached accounts when a refresh fails. |
| `e925ba4` perf(ios) | The new-account sheet closes without waiting for a refresh. |
| `9433ff0` fix(ios) | A delete keeps the repaired snapshot and adjusts balances. |
| `d6cbe13` perf(ios) | Cached Reflect and Rewards reports show at once, then refresh quietly. |

Your server-mode install is unchanged. Adversarial reviews traced the settings migration, Keychain token, snapshot, outbox and launch routing, and none of them can move you into local mode or onto the Welcome screen.

## Before you deploy the backend

- **Deploy order:** the backend no longer serves `/months/**`. The iOS build now on your phone calls those routes from the Plan screen. Install the new iOS build first, then push a `v*` tag, which deploys automatically.
- **No D1 migration is needed.** Take a production backup before deployment and keep backup files and ledger metadata private, outside the repository.

## Needs you

1. **Delete three dead files.** My delete permission was refused, so I left them. Run `trash apps/api/src/ynab-month-activity.ts apps/api/tests/ynab-month-activity.test.ts scripts/verify-month-activity-parity.ts`. Until then, 5 tests in that file fail and every commit shows them. Everything else passes: `bun test` 816 pass, and the full iOS suite ran 614 tests with 0 failures and 2 opt-in skips on the rebased HEAD.
2. **Stale worktree** `.claude/worktrees/agent-a8be16b0a256af6e1`. Its branch is fully merged, but the worktree holds files I couldn't inspect. Look at it before you remove it.
3. **Decisions:**
   - Done (`5d63af0`): a new local plan now takes its currency and date format from the device's region. There is still no screen to change them afterwards. Snapshots don't carry plan settings, so a server plan keeps its own currency after an upload.
   - Pin the bun version for the engine bundle; it was built with 1.4.0.
   - If the engine fails to start in local mode, the app opens Settings, where there is nothing to fix. It needs a proper error screen.

## Not yet verified

- The flow was not tap-tested on a simulator or device. The connect screens have unit tests only. The local-mode screens were checked by in-process renders, not a tap-through, because `axe` couldn't drive the simulator.
- Intermediate commits were not built one by one; only the final tree was. HEAD is verified, but bisecting may land on a commit that doesn't build.
- Engine speed was measured on a Mac with JIT turned off. It has not been profiled on an iPhone with a ledger the size of production.

## Server-mode "no waiting": what shipped and what's next

The P0 items from `offline-writes.md` shipped:

- capture works offline;
- deletes keep the snapshot;
- account create doesn't wait;
- reports are stale-while-revalidate.

P1 is also wired in. In server mode, every transaction write (create, edit, delete, cleared, approve) is saved to `Application Support/HowMuch/Outbox/outbox.json`, shows at once and is sent in batches. Unsent items from the old UserDefaults queue move across on first launch. Refused changes show on the Accounts card with Retry and Discard. Reconcile waits until that account has nothing queued. Nothing sends when the network comes back; it waits for foreground, pull-to-refresh or the next write.

Known limits:

- a cached Reflect overview from an earlier month is dropped rather than shown;
- the saved ledger `nextOffset` is not shifted after a delete.

## Before App Store submission

- Change the associated domain from `webcredentials:howmuch.soon.sg` to `howmuch.tk.sg`.
- Privacy policy URL and privacy manifest.
- Profile the engine on a device without JIT.
- Review how AI-provider keys are handled.
