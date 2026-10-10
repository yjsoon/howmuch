# Own imported YNAB schedules: verification record

Base revision: `86ec867` (main before this change). Branch: `claude/project-thread-yauv4w`.
Date: 2026-10-10. Synthetic data only; no production access, no backup taken here
(see "Not done" below).

## What is checked

1. **Before/after, local SQLite (`run.sh`).** Code from the base revision seeds a file
   database through the real HTTP handler: mirrored schedules (monthly, split with a
   deleted line, deleted, referencing a deleted category and a payee that does not exist,
   transfer), a user overlay (PATCH), a tombstone (DELETE), a local schedule, a `month`
   mirror object, and a second plan with no months. The same file is then opened by this
   checkout, which applies migration 022. Expected: API output identical.
2. **Pruned mirror.** The schedule, subtransaction, month and transaction mirror rows are
   deleted from the copy. Expected: API output still identical (schedules, single reads,
   category guard 409 on the YNAB plan, 201 on the native plan).
3. **Writes after pruning.** PATCH and DELETE of imported schedules work; re-importing
   an edited schedule does not overwrite the edit; a schedule new from sync appears,
   with its line; re-importing a split schedule whose lines YNAB replaced keeps the
   original lines (no accumulation).
4. **D1 migration, wrangler local D1 (`d1-local.sh`).** 0001-0018, fixture rows, then
   0019. A copyable fixture gives the expected rows; a schedule naming a missing account
   makes the migration fail with nothing changed (no rows, no column, not recorded).

## Commands

```
.amp/in/artifacts/own-ynab-schedules/run.sh          # 1-3, output in run-output.txt
.amp/in/artifacts/own-ynab-schedules/d1-local.sh     # 4, output in d1-local-output.txt
cd apps/api && bun test                              # 441 pass
bun test scripts/ynab-d1-bootstrap.test.ts           # 8 pass (copies owned schedules, parity-checked)
```

## Observed

- `run.sh`: schema 021 -> 022; 7 `ynab-overlay` rows and 1 `howmuch-local` row; 4 line
  rows; `plan-ynab` marked `ynab_sourced = 1`, `plan-native` 0; **IDENTICAL** after the
  migration and **IDENTICAL** after pruning 12 mirror rows. `before.json` holds the
  compared output (6 listed schedules, 4 lines, guard 409/201).
- Writes after pruning: patch 200, delete 200, edit kept on re-import (`after edit`, -700),
  split schedule re-imported with replacement lines still has lines a, b totalling -90000,
  new schedule with 1 line.
- `d1-local.sh`: case 1 copies 3 schedules (one tombstone) and the 2 live lines, nulls the
  unresolvable payee reference, marks the plan; case 2 fails with
  `FOREIGN KEY constraint failed` and leaves `edits 0, marker_column 0, migration_recorded 0`.

## Month activity (migration 0017)

`ynab_source_month_activity` is a stored table, filled once from the mirror. Nothing in
`apps/api/src` reads it (the docs already call it a retained legacy table), and deleting
mirror transactions later does not touch it. It does not depend on the mirror.

## Not done

- No production backup or migration: `scripts/backup-d1.sh` needs the Tinkertanker
  wrangler profile, which this environment does not have. Run it, then apply 0019, then
  check the counts in docs/deployment.md.
- The iOS engine bundle and its copy of the migrations were not rebuilt: the build
  needs Bun 1.4.0 and this environment has 1.4.2. Run `bun run build:ios-engine` with
  Bun 1.4.0 before the next iOS cut.
