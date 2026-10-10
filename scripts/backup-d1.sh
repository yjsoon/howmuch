#!/usr/bin/env bash
# Backs up HowMuch production D1 (Tinkertanker account) to a local, gitignored
# SQL dump, validates it against live count-only statistics, records a SHA-256
# checksum, and prunes older archives.
#
#   scripts/backup-d1.sh
#
# Read-only against production: this script only runs `wrangler d1 export` and
# count-only `wrangler d1 execute` queries. It never writes to D1, never runs
# migrations, and never deploys. It never prints row contents, payees, memos,
# or amounts — only counts, paths, and sizes.
#
# Restoring is NOT this script's job and is not a single command. Follow the
# chunked schema/data/triggers procedure in docs/deployment.md ("Restoring or
# bulk-loading D1 data"); budget roughly 30 minutes.
#
# Env overrides:
#   HOWMUCH_BACKUP_DIR               default <repo>/data/backups
#   HOWMUCH_BACKUP_RETENTION_MONTHS  default 6
#   HOWMUCH_BACKUP_COUNT_TOLERANCE   default 50   (max abs diff vs live counts)
#   HOWMUCH_BACKUP_MIN_BYTES         default 52428800   (50 MiB)
#   HOWMUCH_BACKUP_EXPECTED_BYTES    default 209715200  (200 MiB, warn band)
#   HOWMUCH_BACKUP_MAX_BYTES         default 1073741824 (1 GiB)
set -euo pipefail
# The dump is a complete, unencrypted ledger. Keep it and its checksum
# owner-only (mode 600), like the other sensitive files under data/.
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKER_DIR="$ROOT_DIR/apps/worker"

PROFILE="tinkertanker"
ENV_NAME="tk"
# Primary since the 2026-09-12 SIN cutover (#183). The pre-cutover KIX database
# howmuch-production (df039dbc-6dda-4150-9dc3-5854a8ca6818) is kept frozen as a
# rollback snapshot; never back up or write to it.
DB_NAME="howmuch-production-sg"
DB_ID="d13295f9-10d4-4ac0-bf62-b3e8c78cbf29"

BACKUP_DIR="${HOWMUCH_BACKUP_DIR:-$ROOT_DIR/data/backups}"
RETENTION_MONTHS="${HOWMUCH_BACKUP_RETENTION_MONTHS:-6}"
COUNT_TOLERANCE="${HOWMUCH_BACKUP_COUNT_TOLERANCE:-50}"
MIN_BYTES="${HOWMUCH_BACKUP_MIN_BYTES:-52428800}"
EXPECTED_BYTES="${HOWMUCH_BACKUP_EXPECTED_BYTES:-209715200}"
MAX_BYTES="${HOWMUCH_BACKUP_MAX_BYTES:-1073741824}"

# Count-only comparison set. Schema-level table count is compared exactly;
# these row counts are allowed to drift by COUNT_TOLERANCE because production
# may accept a few writes during a backup run.
COUNT_TABLES="plans accounts categories payees transactions subtransactions source_events ynab_raw_objects scheduled_transaction_edits scheduled_subtransaction_edits"

fail() { echo "backup-d1: $*" >&2; exit 1; }

command -v sqlite3 >/dev/null 2>&1 || fail "sqlite3 not found on PATH"
command -v shasum >/dev/null 2>&1 || fail "shasum not found on PATH"
command -v jq >/dev/null 2>&1 || fail "jq not found on PATH"

WRANGLER="${WRANGLER:-$ROOT_DIR/node_modules/.bin/wrangler}"
if [ ! -x "$WRANGLER" ]; then
  WRANGLER="$(command -v wrangler || true)"
fi
[ -n "$WRANGLER" ] || fail "wrangler not found (looked in node_modules/.bin and PATH)"
run_wrangler() { ( cd "$WORKER_DIR" && "$WRANGLER" "$@" ); }

mkdir -p "$BACKUP_DIR"
LOG_FILE="$BACKUP_DIR/.backup-d1.log"

# The destination must never be committed. data/ is gitignored; refuse to write
# a dump anywhere inside the repo that git does not ignore.
case "$BACKUP_DIR" in
  "$ROOT_DIR"/*)
    git -C "$ROOT_DIR" check-ignore -q "$BACKUP_DIR" \
      || fail "backup directory is inside the repo but not gitignored: $BACKUP_DIR"
    ;;
  *) : ;;
esac

DATE_UTC="$(date -u +%F)"
DUMP="$BACKUP_DIR/$DB_NAME-$DATE_UTC.sql"
PARTIAL="$DUMP.partial"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/howmuch-d1-backup.XXXXXX")"
LOCK_DIR="$BACKUP_DIR/.backup-d1.lock"
LOCK_HELD=0
cleanup() {
  rm -rf "$WORK_DIR"
  # Only release the lock if this run created it.
  if [ "$LOCK_HELD" = 1 ]; then rmdir "$LOCK_DIR" 2>/dev/null || true; fi
  rm -f "$PARTIAL"
}
trap cleanup EXIT

mkdir "$LOCK_DIR" 2>/dev/null || fail "another backup appears to be running (remove $LOCK_DIR if stale)"
LOCK_HELD=1

echo "backup-d1: verifying Tinkertanker account and $DB_NAME ..."
if ! run_wrangler d1 list --profile "$PROFILE" --json >"$WORK_DIR/d1-list.json" 2>>"$LOG_FILE"; then
  fail "could not list D1 databases for profile '$PROFILE' (see $LOG_FILE)"
fi
LISTED_ID="$(jq -r --arg n "$DB_NAME" '.[] | select(.name == $n) | .uuid' "$WORK_DIR/d1-list.json" | head -n1)"
[ "$LISTED_ID" = "$DB_ID" ] \
  || fail "profile '$PROFILE' does not expose $DB_NAME as $DB_ID (got '${LISTED_ID:-none}'); refusing to proceed"

counts_sql() {
  # Exclude Cloudflare's internal _cf_* tables (notably _cf_KV): D1 exports
  # omit them, so live sqlite_master is one higher than a loaded dump.
  local sql="SELECT (SELECT count(*) FROM sqlite_master WHERE type='table' AND substr(name,1,4) != '_cf_') AS table_count"
  local t
  for t in $COUNT_TABLES; do
    sql="$sql, (SELECT count(*) FROM $t) AS $t"
  done
  printf '%s;' "$sql"
}

echo "backup-d1: exporting $DB_NAME (env $ENV_NAME) ..."
if ! run_wrangler d1 export "$DB_NAME" --env "$ENV_NAME" --remote --profile "$PROFILE" \
      --output "$PARTIAL" --skip-confirmation >>"$LOG_FILE" 2>&1; then
  fail "d1 export failed (see $LOG_FILE)"
fi
[ -s "$PARTIAL" ] || fail "export produced an empty dump"

SIZE="$(wc -c < "$PARTIAL" | tr -d ' ')"
[ "$SIZE" -ge "$MIN_BYTES" ] || fail "dump is only $SIZE bytes (< min $MIN_BYTES); treating as truncated"
[ "$SIZE" -le "$MAX_BYTES" ] || fail "dump is $SIZE bytes (> max $MAX_BYTES); unexpected"
if [ "$SIZE" -lt $((EXPECTED_BYTES / 2)) ] || [ "$SIZE" -gt $((EXPECTED_BYTES * 3 / 2)) ]; then
  echo "backup-d1: WARNING dump size $SIZE is far from the ~$EXPECTED_BYTES byte ballpark" >&2
fi

echo "backup-d1: validating dump in a throwaway sqlite copy ..."
LOCAL_DB="$WORK_DIR/local-copy.sqlite"
if ! sqlite3 -bail "$LOCAL_DB" <"$PARTIAL" >/dev/null 2>>"$LOG_FILE"; then
  fail "dump did not load into a local sqlite copy (see $LOG_FILE)"
fi

if ! run_wrangler d1 execute DB --env "$ENV_NAME" --remote --profile "$PROFILE" \
      --json --command "$(counts_sql)" >"$WORK_DIR/prod-counts.json" 2>>"$LOG_FILE"; then
  fail "could not read count-only statistics from production (see $LOG_FILE)"
fi
PROD_ROW="$(jq -c -e '.[0].results[0]' "$WORK_DIR/prod-counts.json")" || fail "unexpected production count output"
LOCAL_ROW="$(sqlite3 -json "$LOCAL_DB" "$(counts_sql)")" || fail "unexpected local count output"
LOCAL_ROW="$(printf '%s' "$LOCAL_ROW" | jq -c -e '.[0]')" || fail "unexpected local count output"

for t in $COUNT_TABLES; do
  p="$(jq -r --arg k "$t" '.[$k]' <<<"$PROD_ROW")"
  l="$(jq -r --arg k "$t" '.[$k]' <<<"$LOCAL_ROW")"
  d=$(( p - l ))
  if [ "$d" -lt 0 ]; then d=$(( -d )); fi
  if [ "$d" -gt "$COUNT_TOLERANCE" ]; then
    fail "count mismatch for $t: dump=$l live=$p (diff $d > tolerance $COUNT_TOLERANCE)"
  fi
done

PROD_TABLES="$(jq -r '.table_count' <<<"$PROD_ROW")"
LOCAL_TABLES="$(jq -r '.table_count' <<<"$LOCAL_ROW")"
[ "$PROD_TABLES" = "$LOCAL_TABLES" ] \
  || fail "table count mismatch: dump=$LOCAL_TABLES live=$PROD_TABLES"

# Validation passed: publish the dump atomically and record its checksum.
mv -f "$PARTIAL" "$DUMP"
shasum -a 256 "$DUMP" >"$DUMP.sha256"
SHA="$(cut -d' ' -f1 <"$DUMP.sha256")"

prune() {
  local newest_first kept_months pruned=0 kept=0 keep f month bname rel
  kept_months=""
  # shellcheck disable=SC2012
  newest_first="$(ls -1 "$BACKUP_DIR/$DB_NAME"-????-??-??.sql 2>/dev/null | sort -r || true)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    bname="$(basename "$f")"
    rel="${bname#"$DB_NAME"-}"
    month="${rel%-??.sql}"
    keep=1
    case " $kept_months " in
      *" $month "*) keep=0 ;;
    esac
    if [ "$keep" = 1 ] && [ "$kept" -ge "$RETENTION_MONTHS" ]; then
      keep=0
    fi
    if [ "$keep" = 1 ]; then
      kept_months="$kept_months $month"
      kept=$((kept + 1))
    else
      pruned=$((pruned + 1))
      rm -f "$f" "$f.sha256"
    fi
  done <<<"$newest_first"
  printf '%s %s' "$kept" "$pruned"
}

# shellcheck disable=SC2046
set -- $(prune)
KEPT_FILES="$1"
PRUNED_FILES="$2"

HUMAN_SIZE="$(du -h "$DUMP" | cut -f1)"
echo "backup-d1: OK"
echo "  dump:      $DUMP"
echo "  size:      $SIZE bytes ($HUMAN_SIZE)"
echo "  checksum:  $DUMP.sha256 (sha256 $SHA)"
echo "  tables:    $LOCAL_TABLES"
printf '  counts:   '
for t in $COUNT_TABLES; do
  printf ' %s=%s' "$t" "$(jq -r --arg k "$t" '.[$k]' <<<"$LOCAL_ROW")"
done
printf '\n'
echo "  retained:  $KEPT_FILES archive(s) (newest per month, max $RETENTION_MONTHS months)"
echo "  pruned:    $PRUNED_FILES older archive(s)"
echo "  restore:   manual chunked procedure in docs/deployment.md, budget ~30 minutes"
