# Rewards native manage plan

HowMuch users add, edit, and delete reward cards on web and on iOS. They stop needing a Rewards Tracker export for the daily loop. Import stays as a one-off migration. One `CreditCard` JSON shape lives on `plan_id` and `SimpleRewardsCalculator` scores it. PR order is `rewards-card-api`, then `rewards-web-manage`, then `rewards-ios-manage`.

## How to read this

One box is one unit of work. Every box names the evidence that checks it. A nested box is a sub-step of the box above it. Check a box only when its evidence exists, a file, a log line, a screenshot, a test run, or a SHA. The body is a how-to. The appendices explain and record.

The program runs `pstack/skills/poteto-mode/playbooks/autopilot-stack.md`. The operator lands the stack. Owners stop at STACK-READY for `rewards-card-api`, `rewards-web-manage`, and `rewards-ios-manage`.

Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

## Program checklist

### Arm the program

- [ ] State the protocol and this plan to the operator, then stop. Start execution only on her explicit go.
- [ ] On her go, arm a `/goal` with this exact text. "`docs/plans/rewards-native-manage.md`. PRs `rewards-card-api`, `rewards-web-manage`, `rewards-ios-manage`. Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. The operator lands the stack. Done when both clients create, edit, and delete a card mapped to a HowMuch account and the Rewards report scores it without a JSON file."
- [ ] Read these from trunk at program start. Re-read them at every tick.
  - [ ] `git show origin/main:pstack/skills/poteto-mode/playbooks/autopilot-stack.md`
  - [ ] `git show origin/main:pstack/skills/swarm/SKILL.md`
  - [ ] `git show origin/main:.cursor/skills/verify-howmuch/SKILL.md`
  - [ ] `git show origin/main:pstack/skills/poteto-mode/playbooks/opening-a-pr.md`
  - [ ] `git show origin/main:pstack/skills/how/SKILL.md`
  - [ ] `git show origin/main:pstack/skills/unslop/SKILL.md`
  - [ ] `git show origin/main:pstack/skills/technical-writing/SKILL.md`
- [ ] Arm the 30-minute audit tick. In a local session, a real terminal `/loop`. In a cloud root, a cloud-sleeper wake chain. Never leave the cadence to memory.
- [ ] Use this tick prompt, verbatim. "Re-read the execution playbook from trunk and the armed /goal. Audit the operation against both and fix drift in this tick. Probe every active lane and judge progress by side effects only. Stand down a stuck lane and dispatch its replacement now. Then send the operator a status message, whether or not anything changed, with the queue table of PR, owner, state, and head SHA, the verdicts since the last tick, what merged, open operator gates, and blockers."
- [ ] On the operator's hold or stand-down, send every owner a zero-writes order at once.

### Spawn owners

- [ ] Spawn one owner per PR with the full lifecycle the execution playbook names.
- [ ] Follow this dependency graph. Start dependent work only after its parent merges, or base it on the parent branch when the execution playbook stacks.
  - [ ] `rewards-card-api` is first. It branches from `main`.
  - [ ] `rewards-web-manage` after `rewards-card-api`.
  - [ ] `rewards-ios-manage` after `rewards-card-api`. It may stack on `rewards-web-manage` so the chain stays linear.
- [ ] Hold the file boundaries. `rewards-card-api` touches only `apps/api/**` and `docs/api-contract.md`. `rewards-web-manage` touches only `apps/web/**`, `docs/frontend/brief.md`, and `.cursor/skills/verify-howmuch/features/**`. `rewards-ios-manage` touches only `apps/ios/**` and `.cursor/skills/verify-howmuch/features/ios-*.md`.
- [ ] Hold the review gate. `rewards-web-manage` and `rewards-ios-manage` change an interaction. They wait for the operator's review in chat with screenshots and a video before merge.

### PR mechanics, for every PR

- [ ] Resolve the forge once. Default to `gh`; if `command -v origin` succeeds and Origin can resolve the repository, use `origin pr` for every PR operation. Record any fallback to `gh`. Never require `gt`.
- [ ] Open the PR ready, never draft, with `origin pr create --status open --base <base-branch>` or `gh pr create --base <base-branch>` according to the resolved forge. A stack child targets its parent branch.
- [ ] Run the repo's lint and typecheck once before the PR-facing push. Push with hooks on.
- [ ] Run `/deslop` before each commit and `/no-comments` before review.
- [ ] Triage every Bugbot and security-reviewer comment per `../references/bugbot-triage.md`.
- [ ] Rebase onto current trunk before babysit and again before the merge-ready report.

### Verdict and merge, for every PR

- [ ] At the merge-ready head SHA, run the swarm per `pstack/skills/swarm/SKILL.md`. One gates lane. The ten live lanes from the PR's **Verify, live** block. The perf lane from its **Verify, perf** block. One audit lane that reads the diff and the receipts and distrusts the PR body.
- [ ] Clean only when every lane is `PASS`. Findings go back to the owner. A new head gets a fresh swarm and a fresh verdict.
- [ ] The root appends the PR to the base-branch stack. Compare `git patch-id` for the base-to-head diff at the verdict SHA against the new base-to-head diff. An unchanged patch-id keeps the code verdict. A changed patch goes through swarm again. The operator lands the chain bottom-up. No owner merges.

### Boot recipe, for every live lane

Each live lane runs on its own cloud VM at the PR head. Drive web through `.cursor/skills/verify-howmuch/SKILL.md`. Drive iOS through that skill plus `apps/ios/AGENTS.md`.

- [ ] `git fetch origin <head-branch> && git checkout <head SHA>`.
- [ ] Run `control-howmuch launch` then `control-howmuch doctor`. Wait until doctor prints `ok health` and `ok web_title=HowMuch`. Complete first-owner setup as `verifier`.
- [ ] Deliver input only through verify-howmuch recipes, Cursor browser, or Simulator. Read-only diagnostics are `control-howmuch http` and `control-howmuch doctor`.
- [ ] Save every screenshot to `/tmp/swarm-<pr-id>/worker-<n>/<slug>.png` and return the paths with the report.

## Store reward cards through the API (rewards-card-api)

**Depends on.** None.

**Files.**

- [ ] Edit `apps/api/src/http.ts`.
- [ ] Edit `apps/api/src/repository.ts`.
- [ ] Create `apps/api/src/rewards/write.ts`.
- [ ] Create `apps/api/src/rewards/write.test.ts`.
- [ ] Edit `apps/api/src/rewards/parse.ts`.
- [ ] Edit `apps/api/tests/api.test.ts`.
- [ ] Edit `docs/api-contract.md`.

**Build.**

- [ ] Add `upsertRewardsTrackerCard` and `deleteRewardsTrackerCard` on `LedgerRepository` in `apps/api/src/repository.ts`.
- [ ] Parse and validate one `CreditCard` in `parseCreditCard` and `apps/api/src/rewards/write.ts`. Require `ynabAccountId` to be a live plan account.
- [ ] Handle `POST`, `PATCH`, and `DELETE` on `/api/rewards/cards` in `apps/api/src/http.ts`. Keep `GET` and `POST` on `/api/import/rewards-tracker`.
- [ ] Persist miles valuation on the snapshot `settings` object through `PATCH /api/rewards/settings`.
- [ ] Document the new routes in `docs/api-contract.md`.

**You see.**

- [ ] `POST /api/rewards/cards` with a Travel Card body returns 201 and `GET /api/import/rewards-tracker` lists that card.
- [ ] `GET /api/reports/rewards` scores the new card against HowMuch transactions.
- [ ] `DELETE /api/rewards/cards` sets `deleted = 1`. The report omits the card.
- [ ] A card whose `ynabAccountId` is missing or unknown returns 422.
- [ ] Import still upserts by `(plan_id, id)` and still strips secrets.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] `apps/api/src/rewards/write.test.ts` covers create, patch, soft-delete, unknown account, and missing account id. Run `bun test apps/api/src/rewards/write.test.ts`.
- [ ] `apps/api/tests/api.test.ts` covers the HTTP routes. Run `bun test apps/api/tests/api.test.ts`.
- [ ] Existing import and calculator tests still pass. Run `bun test apps/api/src/importers/rewards-tracker.test.ts apps/api/src/rewards/build.test.ts apps/api/src/rewards/engine/simple-calculator.test.ts`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `grok-4.6-fast-xhigh` at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Run create-card then open Rewards on trunk and head. If trunk lacks the feature, record that and gate the 201 from `POST /api/rewards/cards` plus the new card on `GET /api/reports/rewards`. Save `card-api-regression.png`. Pass when trunk has no write route and head shows the created card on Rewards All.
- [ ] Lane 2. Create a cashback card mapped to `acct-credit`. Save `card-api-cashback.png`. Pass when the snapshot lists the card and Rewards shows a Cashback tile.
- [ ] Lane 3. Create a miles card with Dining red and Online blue subcategories. Save `card-api-miles-flags.png`. Pass when the Travel Card tile lists both flags.
- [ ] Lane 4. PATCH `earningRate` on the miles card. Save `card-api-patch-rate.png`. Pass when a second report GET shows a changed Value figure.
- [ ] Lane 5. DELETE the cashback card. Save `card-api-delete.png`. Pass when Rewards omits that tile and the snapshot marks `deleted`.
- [ ] Lane 6. POST a card with an unknown `ynabAccountId`. Save `card-api-unknown-account.png`. Pass when the response is 422 and no row is inserted.
- [ ] Lane 7. POST a card with no `ynabAccountId`. Save `card-api-missing-account.png`. Pass when the response is 422.
- [ ] Lane 8. Import `fixtures/rewards-tracker-export.json` after a manual card that the file omits. Save `card-api-reimport.png`. Pass when Travel Card is present and the omitted manual card is gone.
- [ ] Lane 9. PATCH miles valuation then reload Rewards. Save `card-api-miles-valuation.png`. Pass when the miles card Value figure changes.
- [ ] Lane 10. PATCH the same card body twice. Save `card-api-idempotent-patch.png`. Pass when the card id stays the same and the report has one tile.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Wall time for `GET /api/reports/rewards?plan_id=local-plan` after the demo import, plus wall time for one `POST /api/rewards/cards` on head only.
- [ ] Probe. Run the GET three times on trunk and three times on head, interleaved. Then run the POST three times on head. Record each ms value.
- [ ] Baseline. Record the trunk GET median first.
- [ ] Rule. Head GET median fails if it exceeds the trunk median by 50 ms. POST median fails if it exceeds 300 ms.

**Review gate.** None. rewards-card-api is not review-gated.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The root appends it to the base-branch stack and the operator lands it bottom-up.

## Manage reward cards on web (rewards-web-manage)

**Depends on.** rewards-card-api.

**Files.**

- [ ] Edit `apps/web/src/pages/Rewards.tsx`.
- [ ] Create `apps/web/src/pages/RewardCardEdit.tsx`.
- [ ] Edit `apps/web/src/main.tsx`.
- [ ] Edit `apps/web/src/api/client.ts`.
- [ ] Edit `apps/web/src/api/types.ts`.
- [ ] Edit `apps/web/src/app.css`.
- [ ] Edit `apps/web/src/pages/Settings.tsx`.
- [ ] Edit `docs/frontend/brief.md`.
- [ ] Create `.cursor/skills/verify-howmuch/features/rewards-card-edit.md`.
- [ ] Edit `.cursor/skills/verify-howmuch/features/rewards.md`.
- [ ] Edit `.cursor/skills/verify-howmuch/features/README.md`.

**Build.**

- [ ] Add `api.createRewardCard`, `api.updateRewardCard`, `api.deleteRewardCard`, and `api.updateRewardSettings` in `apps/web/src/api/client.ts`.
- [ ] Put **Add card** on the Rewards empty state and on the filled board in `Rewards.tsx`.
- [ ] Build the editor in `RewardCardEdit.tsx` using HowMuch field styles from `ScheduledTransactions.tsx` and `ApiTokens.tsx`. Cover name, issuer, cashback or miles, HowMuch account, featured, billing cycle, reward period, promotional period, earning rate, block size, minimum spend, maximum spend, flag subcategories including unflagged, spending tiers, and import of HowMuch categories onto those flags.
- [ ] Route `/rewards/:cardId` in `apps/web/src/main.tsx`. A tile click opens the editor. The editor lists that card's ledger rows with a flag picker that PATCHes the existing transaction. Delete uses the existing confirm pattern.
- [ ] Hide capped cards on the Rewards board when maximum spend is exceeded. Keep them visible on the editor.
- [ ] Keep Settings then Rewards import. Add miles valuation on Rewards or Settings. Do not add a `TagMapping` editor. The calculator keys on `flagColor`.
- [ ] Write the verify recipe `rewards-card-edit.md` and point `rewards.md` at Add card.

**You see.**

- [ ] A signed-in user with no cards sees **Add card** and the import link.
- [ ] Saving a new card mapped to Travel Card shows a tile on `/rewards` with All selected.
- [ ] Editing a rate and saving updates the tile without a file upload.
- [ ] Deleting the last card returns the empty state.
- [ ] A capped card drops off the board and remains on its editor URL.
- [ ] Import still creates Travel Card from `fixtures/rewards-tracker-export.json`.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] `apps/web/src/api/client.test.ts` covers the new client methods. Run `bun test apps/web/src/api/client.test.ts`.
- [ ] Typecheck the web app. Run `bunx tsc --noEmit -p apps/web`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `grok-4.6-fast-xhigh` at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Open `/rewards` on trunk and head with no cards stored. If trunk lacks Add card, record that and gate the Add card control plus a saved tile. Save `web-add-regression.png`. Pass when head empty state has Add card and trunk does not.
- [ ] Lane 2. Add a cashback card mapped to Travel Card. Save `web-add-cashback.png`. Pass when a Cashback tile named by the form appears on All.
- [ ] Lane 3. Open the tile, set Dining red at 4x and Online blue at 3x, save. Save `web-edit-flags.png`. Pass when the tile lists both flags.
- [ ] Lane 4. Set minimum spend above current spend. Save `web-min-spend.png`. Pass when the progress label is Minimum spend, not Minimum met.
- [ ] Lane 5. Set maximum spend below current spend. Save `web-max-spend.png`. Pass when the tile uses the capped class.
- [ ] Lane 6. Delete the card and confirm. Save `web-delete.png`. Pass when Rewards shows the empty state again.
- [ ] Lane 7. Import `fixtures/rewards-tracker-export.json` from Settings then Rewards import. Save `web-import-still.png`. Pass when Travel Card is a Miles tile with Dining and Online.
- [ ] Lane 8. Set billing cycle to billing day 15, reload `/rewards/:cardId`. Save `web-billing-cycle.png`. Pass when the editor still shows billing day 15.
- [ ] Lane 9. Change a transaction flag on the register to red and return to Rewards. Save `web-flag-scoring.png`. Pass when Dining spend is greater than $0.00.
- [ ] Lane 10. Resize to 390px width and add a card. Save `web-mobile-add.png`. Pass when Add card is reachable from Open menu then Rewards and the save succeeds.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Time from Rewards navigation to the headline Qualifying spend on All, after Travel Card is stored. On head, also time from Add card submit to the new tile.
- [ ] Probe. Measure both times with the browser at trunk and head. Interleave three loads of Rewards. Then measure three saves on head.
- [ ] Baseline. Record the trunk Rewards load median first.
- [ ] Rule. Head Rewards load median fails if it exceeds the trunk median by 200 ms. Add-card submit to tile fails if it exceeds 800 ms.

**Review gate.** The operator reviews before merge.

- [ ] Copy lane 2 and lane 3 screenshots into `/tmp/rewards-web-manage-review-add.png` and `/tmp/rewards-web-manage-review-flags.png`.
- [ ] Record a 30 to 60 second video of add, edit flags, and delete on a lane VM. Save it as `/tmp/rewards-web-manage-review.mp4`.
- [ ] Post the screenshots and the video in chat. Stop at merge-ready. Wait for the operator's click.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The root appends it to the base-branch stack and the operator lands it bottom-up.

## Manage reward cards on iOS (rewards-ios-manage)

**Depends on.** rewards-card-api.

**Files.**

- [ ] Create `apps/ios/HowMuch/Views/RewardCardEditorView.swift`.
- [ ] Edit `apps/ios/HowMuch/Views/RewardsView.swift`.
- [ ] Edit `apps/ios/HowMuch/Views/RewardsImportView.swift`.
- [ ] Edit `apps/ios/HowMuch/Services/APIClient.swift`.
- [ ] Edit `apps/ios/HowMuch/Models/APIModels.swift`.
- [ ] Create `apps/ios/HowMuchTests/RewardCardEditorTests.swift`.
- [ ] Create `.cursor/skills/verify-howmuch/features/ios-rewards-card-edit.md`.
- [ ] Edit `.cursor/skills/verify-howmuch/features/ios-rewards.md`.
- [ ] Edit `.cursor/skills/verify-howmuch/features/README.md`.

**Build.**

- [ ] Add create, update, and delete methods on `APIClient` next to `importRewardsTracker`.
- [ ] Mirror `NewAccountSheet`, `EditAccountSheet`, and `ScheduledTransactionEditorView` in `RewardCardEditorView`. Cover the same fields as the web editor, including unflagged and category-to-flag import.
- [ ] Put **Add card** on the Rewards empty state. Tile tap opens the editor. The editor lists that card's ledger rows with a flag picker. Keep **Rewards import**.
- [ ] Hide capped cards on the tab board. Keep them on the editor.
- [ ] Decode write errors into the existing phase error label. Do not add a `TagMapping` editor.
- [ ] Add native tests in `RewardCardEditorTests.swift`. Run them with `scripts/ios-xcodebuild.sh test`.
- [ ] Write `ios-rewards-card-edit.md` and point `ios-rewards.md` at Add card.

**You see.**

- [ ] The Rewards tab empty state has Add card and Rewards import.
- [ ] Saving a card mapped to Travel Card shows a tile on All Time after refresh.
- [ ] Editing flags updates the tile.
- [ ] Deleting the last card returns the empty state.
- [ ] A capped card drops off the tab board and remains in the editor.
- [ ] Import still lists Travel Card under Stored cards.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] `apps/ios/HowMuchTests/RewardCardEditorTests.swift` covers payload encoding and account-id validation. Run `scripts/ios-xcodebuild.sh test`.
- [ ] Existing `RewardsReportTests` still pass under the same command.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `grok-4.6-fast-xhigh` at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Open the Rewards tab on trunk and head with no cards stored. If trunk lacks Add card, record that and gate the Add card button plus a saved tile on All Time. Save `ios-add-regression.png`. Pass when head empty state has Add card and trunk does not.
- [ ] Lane 2. Add a cashback card mapped to Travel Card. Save `ios-add-cashback.png`. Pass when a Cashback tile appears on All Time.
- [ ] Lane 3. Edit Dining and Online flags and save. Save `ios-edit-flags.png`. Pass when the tile lists both flags.
- [ ] Lane 4. Set minimum spend above current spend. Save `ios-min-spend.png`. Pass when the tile shows Minimum spend, not Minimum met.
- [ ] Lane 5. Set maximum spend below current spend. Save `ios-max-spend.png`. Pass when the tile looks capped.
- [ ] Lane 6. Delete the card and confirm. Save `ios-delete.png`. Pass when the tab shows the empty state.
- [ ] Lane 7. Import `fixtures/rewards-tracker-export.json` from Rewards import. Save `ios-import-still.png`. Pass when Stored cards lists Travel Card and the tab shows the Miles tile.
- [ ] Lane 8. Set billing day 15, leave the editor, open it again. Save `ios-billing-cycle.png`. Pass when billing day 15 is still selected.
- [ ] Lane 9. Pull to refresh after a web-side card create on the same plan. Save `ios-sync-from-web.png`. Pass when the web-created card appears without a local import.
- [ ] Lane 10. Rotate or use a compact height and add a card. Save `ios-compact-add.png`. Pass when the editor save button stays reachable and the tile appears.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Time from selecting the Rewards tab to the Qualifying spend headline on All Time, with Travel Card stored. On head, also time from editor Save to the updated tile.
- [ ] Probe. Measure tab-open time three times on trunk and head, interleaved. Then measure three saves on head in Simulator.
- [ ] Baseline. Record the trunk tab-open median first.
- [ ] Rule. Head tab-open median fails if it exceeds the trunk median by 200 ms. Save-to-tile fails if it exceeds 800 ms.

**Review gate.** The operator reviews before merge.

- [ ] Copy lane 2 and lane 3 screenshots into `/tmp/rewards-ios-manage-review-add.png` and `/tmp/rewards-ios-manage-review-flags.png`.
- [ ] Record a 30 to 60 second video of add, edit flags, and delete on a lane VM. Save it as `/tmp/rewards-ios-manage-review.mp4`.
- [ ] Post the screenshots and the video in chat. Stop at merge-ready. Wait for the operator's click.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The root appends it to the base-branch stack and the operator lands it bottom-up.

## Close the program

- [ ] Every box above is checked with its evidence.
- [ ] Reply to the operator with the report the execution playbook names.

## Appendix A. Prototype evidence

No throwaway prototype ran. HowMuch already has the `CreditCard` type, `SimpleRewardsCalculator`, and `upsertRewardsTrackerSnapshot`. The HowMuch editorial ledger in `docs/frontend/brief.md` already sets layout. Trunk SHA at plan write is `d65ae91`. Unproven until `rewards-card-api` lands, a live POST that the report scores without import.

## Appendix B. Alternatives rejected

Wrap `rewards.soon.sg` or the Expo app inside HowMuch. It would ship a second visual language and keep a YNAB PAT. HowMuch is the ledger. Cards map to HowMuch accounts.

Port the legacy `RewardRule` engine in `packages/app-core/src/rewards-engine/calculator.ts`. Live Rewards Tracker sends `/rules` and `/card-rules` to the dashboard. The live editor is `CardSettingsEditor`. HowMuch already vendors `SimpleRewardsCalculator`. Snapshot `rules` and `tagMappings` do not score. Flag colour on `CardSubcategory` does.

Bring Cloud Sync, the statement formatter, the Agent API page, recommendations, or theme groups. Recommendations stay off in `featureFlags.ts`. Formatter is a different product. Cloud Sync and PAT are what HowMuch import already strips. Plan D1 is the sync. HowMuch already groups tiles by cashback and miles.

New SQL tables for rules and tag mappings. The snapshot JSON and `rewards_tracker_cards.payload_json` already store the live shape. Laziness keeps those tables.

One PR for API, web, and iOS. A break would bury the cause. Sequence-verifiable-units wants one evidence bundle per PR.

## Appendix C. Risks

HowMuch trunk does not vendor `pstack/`. Owners read the plugin copy of autopilot-stack and swarm. The `git show origin/main:pstack/...` boxes will fail until pstack is vendored or the root substitutes the plugin path. Watch this at arm time in every PR.

Linux cloud VMs often lack Simulator. `rewards-ios-manage` live lanes then cannot drive the tab. The owner records the skip, still runs `scripts/ios-xcodebuild.sh test` when Xcode exists, and does not mark Simulator lanes PASS from web. Watch this in `rewards-ios-manage`.

Import remains a full replace. A later export that omits a HowMuch-created card will soft-delete it. An empty `cards` array soft-deletes every card on the plan. The editor copy must say that. Watch this in `rewards-web-manage` and `rewards-ios-manage`.

Subcategories enabled with no matching flag earn 0, including unflagged. Watch this in both editor PRs.

`cursor-team-kit` `control-ui` is not in this repo. Lanes use `verify-howmuch`. Watch this in the boot recipe.

## Appendix D. Links and reading list

Read `yjsoon/ynab-rewards-tracker` `CLAUDE.md`, `apps/web/components/CardSettingsEditor.tsx`, `apps/web/components/CardSubcategoriesEditor.tsx`, `apps/web/components/CategoryImportComposer.tsx`, `apps/web/app/cards/[id]/CardSettings.tsx`, and `packages/app-core/src/rewards-engine/simple-calculator.ts` before editing.

Read HowMuch `apps/api/src/rewards/types.ts`, `apps/api/src/rewards/engine/simple-calculator.ts`, `apps/api/src/importers/rewards-tracker.ts`, `apps/api/src/http.ts`, `apps/web/src/pages/Rewards.tsx`, `apps/web/src/pages/ScheduledTransactions.tsx`, `apps/web/src/pages/ApiTokens.tsx`, `apps/ios/HowMuch/Views/NewAccountSheet.swift`, `apps/ios/HowMuch/Views/EditAccountSheet.swift`, `apps/ios/HowMuch/Views/ScheduledTransactionEditorView.swift`, `docs/api-contract.md`, and `.cursor/skills/verify-howmuch/SKILL.md`.

`rewards-card-api` runs `pstack/skills/how/SKILL.md` Explain on the write path before coding. `rewards-web-manage` and `rewards-ios-manage` run `pstack/skills/interrogate/SKILL.md` on the editor before review. Each owner keeps a `decisions.tsv` trail per `pstack/skills/show-me-your-work/SKILL.md`.
