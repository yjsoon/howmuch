#!/usr/bin/env bash
# Applies migration 0019 with wrangler's local D1 (miniflare) to a database at
# 0018 holding mirrored schedules, then repeats with a schedule that cannot be
# copied (its account does not exist) to show the migration fails atomically.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
W="$ROOT/node_modules/.bin/wrangler"
export CI=1
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
cat > wrangler.jsonc <<'JSON'
{ "name": "d1check", "main": "x.ts", "compatibility_date": "2026-07-18",
  "d1_databases": [{ "binding": "DB", "database_name": "d1check", "database_id": "00000000-0000-0000-0000-000000000000", "migrations_dir": "migrations" }] }
JSON
query() { "$W" d1 execute DB --local --persist-to ./state --json --command "$1" 2>/dev/null | python3 -c "import sys,json; t=sys.stdin.read(); [print(r['results']) for r in json.loads(t[t.index('['):])]"; }
run_case() {
  rm -rf state migrations; mkdir migrations
  cp "$ROOT"/apps/api/d1-migrations/00{01..18}_*.sql migrations/
  "$W" d1 migrations apply DB --local --persist-to ./state >/dev/null 2>&1
  "$W" d1 execute DB --local --persist-to ./state --file "$1" >/dev/null 2>&1
  cp "$ROOT/apps/api/d1-migrations/0019_own_imported_ynab_schedules.sql" migrations/
  "$W" d1 migrations apply DB --local --persist-to ./state 2>&1 | grep -E "✅|ERROR" || true
}
echo "== case 1: all schedules copyable"
run_case "$HERE/d1-seed.sql"
query "SELECT id,origin,account_id,payee_id,category_id,deleted FROM scheduled_transaction_edits ORDER BY id; SELECT id,scheduled_transaction_id,amount_milli FROM scheduled_subtransaction_edits ORDER BY id; SELECT id,ynab_sourced FROM plans;"
echo "== case 2: a schedule names an account that does not exist"
sed -e 's#"account_id":"card"#"account_id":"nowhere"#' "$HERE/d1-seed.sql" > bad.sql
run_case bad.sql
query "SELECT (SELECT count(*) FROM scheduled_transaction_edits) AS edits, (SELECT count(*) FROM pragma_table_info('plans') WHERE name='ynab_sourced') AS marker_column, (SELECT count(*) FROM d1_migrations WHERE name LIKE '0019%') AS migration_recorded"
