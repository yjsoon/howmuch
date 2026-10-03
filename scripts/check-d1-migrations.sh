#!/usr/bin/env bash
# Exits non-zero when the target D1 database has not applied every migration
# in apps/api/d1-migrations. The deploy workflow runs it before
# `wrangler deploy --env tk` so a release cannot go out against an
# unmigrated database. It never applies migrations.
#
#   scripts/check-d1-migrations.sh --env tk --remote        # CI (production)
#   scripts/check-d1-migrations.sh --env tk --local --persist-to <dir>
#
# Arguments are passed to `wrangler d1 execute DB`. Authentication comes from
# the environment (CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID) or --profile.
# CI maps the separate CLOUDFLARE_D1_READ_TOKEN secret to CLOUDFLARE_API_TOKEN.
#
# Read-only: it runs one SELECT on the d1_migrations table. It deliberately
# avoids `wrangler d1 migrations list`, which exits 0 whether or not
# migrations are pending and first runs CREATE TABLE IF NOT EXISTS against
# the database. A token with Account > D1 > Read is enough.
#
# Pending means a *.sql file directly inside the migrations directory whose
# name is not recorded in d1_migrations, matching Wrangler's default
# migrations_pattern and migrations_table. Any error fails closed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKER_DIR="$ROOT_DIR/apps/worker"
MIGRATIONS_DIR="$ROOT_DIR/apps/api/d1-migrations"
WRANGLER="${WRANGLER:-$ROOT_DIR/node_modules/.bin/wrangler}"

fail() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::error::%s\n' "$*" >&2
  else
    printf 'check-d1-migrations: %s\n' "$*" >&2
  fi
  exit 1
}

[ "$#" -gt 0 ] || fail "pass the target, e.g. --env tk --remote"
command -v jq >/dev/null 2>&1 || fail "jq not found on PATH"
[ -x "$WRANGLER" ] || fail "wrangler not found at $WRANGLER (run bun install)"

# The file list below assumes Wrangler's defaults; refuse to guess otherwise.
grep -q '"migrations_dir": "../api/d1-migrations"' "$WORKER_DIR/wrangler.jsonc" ||
  fail "wrangler.jsonc no longer sets migrations_dir to ../api/d1-migrations; update this script"
if grep -Eq '"migrations_(pattern|table)"' "$WORKER_DIR/wrangler.jsonc"; then
  fail "wrangler.jsonc sets migrations_pattern or migrations_table; update this script"
fi

expected="$(find "$MIGRATIONS_DIR" -maxdepth 1 -type f -name '*.sql' ! -name '.*' -exec basename {} \; | LC_ALL=C sort)"
[ -n "$expected" ] || fail "no migration files found in $MIGRATIONS_DIR"

err_file="$(mktemp)"
trap 'rm -f "$err_file"' EXIT

set +e
output="$(cd "$WORKER_DIR" && "$WRANGLER" d1 execute DB "$@" --json \
  --command "SELECT name FROM d1_migrations ORDER BY id" 2>"$err_file")"
status=$?
set -e
if [ "$status" -ne 0 ]; then
  printf '%s\n' "$output" >&2
  cat "$err_file" >&2
  fail "could not read d1_migrations (wrangler exit $status). If the error above is an authentication or permission error, verify the token has Account > D1 > Read (CI uses the CLOUDFLARE_D1_READ_TOKEN secret); see 'CI migration-check token' in docs/deployment.md. If it is 'no such table: d1_migrations', the database has never been migrated or the binding points at the wrong database."
fi

applied="$(jq -r '.[0].results | if type == "array" then .[].name else error("no results array") end' <<<"$output")" ||
  fail "unexpected wrangler output; refusing to continue"
applied="$(printf '%s\n' "$applied" | LC_ALL=C sort)"

pending="$(LC_ALL=C comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$applied"))"
if [ -n "$pending" ]; then
  printf 'Pending D1 migrations:\n%s\n' "$(printf '%s\n' "$pending" | sed 's/^/  /')" >&2
  fail "D1 migrations are pending. Apply them manually as described in docs/deployment.md, then re-run the deploy. This check never applies migrations."
fi

printf 'D1 migrations up to date: %s applied, none pending.\n' "$(printf '%s\n' "$expected" | wc -l | tr -d ' ')"
