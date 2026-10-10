#!/usr/bin/env bash
# Before/after check for the YNAB schedule ownership migration.
# Seeds a database with the BASE revision's code, then opens the same file with
# THIS checkout (which applies migration 022) and compares API output.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEW_ROOT="$(cd "$HERE/../../../.." && pwd)"
BASE_REV="${1:-$(git -C "$NEW_ROOT" rev-parse HEAD)}"
WORK="$(mktemp -d)"
OLD_ROOT="$WORK/base"
git -C "$NEW_ROOT" worktree add --detach "$OLD_ROOT" "$BASE_REV" >/dev/null
ln -s "$NEW_ROOT/node_modules" "$OLD_ROOT/node_modules"
for d in "$NEW_ROOT"/apps/*/node_modules "$NEW_ROOT"/packages/*/node_modules; do
  [ -e "$d" ] && ln -s "$d" "$OLD_ROOT/${d#"$NEW_ROOT/"}" 2>/dev/null || true
done
cleanup() { git -C "$NEW_ROOT" worktree remove --force "$OLD_ROOT" >/dev/null 2>&1 || true; }
trap cleanup EXIT
DB="$WORK/ynab.db"
echo "base revision: $BASE_REV (code that seeds the database)"
echo "this checkout: $(git -C "$NEW_ROOT" rev-parse --short HEAD) + working tree"
bun "$HERE/capture.ts" "$OLD_ROOT" "$DB" seed "$WORK/before.json"
echo "schema before: $(sqlite3 "$DB" "select max(version) from schema_migrations" 2>/dev/null || bun -e "console.log(new (require('bun:sqlite').Database)('$DB').query('select max(version) v from schema_migrations').get().v)")"
bun "$HERE/capture.ts" "$NEW_ROOT" "$DB" read "$WORK/after.json"
bun -e "const d=new (require('bun:sqlite').Database)('$DB');console.log('schema after:',d.query('select max(version) v from schema_migrations').get().v);console.log('edits by origin:',JSON.stringify(d.query('select origin,count(*) n from scheduled_transaction_edits group by origin').all()));console.log('sub edits:',d.query('select count(*) n from scheduled_subtransaction_edits').get().n);console.log('plans marked ynab_sourced:',JSON.stringify(d.query('select id,ynab_sourced from plans order by id').all()))"
diff -u "$WORK/before.json" "$WORK/after.json" && echo "IDENTICAL: API output before and after the migration"
bun "$HERE/capture.ts" "$NEW_ROOT" "$DB" prune "$WORK/pruned.json"
diff -u "$WORK/before.json" "$WORK/pruned.json" && echo "IDENTICAL: API output after pruning schedule, month and transaction mirror rows"
bun "$HERE/capture.ts" "$NEW_ROOT" "$DB" writes "$WORK/writes.json"
cat "$WORK/writes.json"
cp "$WORK/before.json" "$HERE/before.json"; cp "$WORK/pruned.json" "$HERE/after-pruned.json"; cp "$WORK/writes.json" "$HERE/writes-after-prune.json"
