#!/usr/bin/env bash
# Darwin product clock for Rewards save-to-tile. Do not use axe describe-ui
# as t0 or as the wait. Capture simctl screenshots first, OCR afterwards.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OCR="$ROOT/apps/ios/scripts/ocr-screenshot.swift"
NEEDLE="${NEEDLE:-travel card}"
MAX_MS="${MAX_MS:-2000}"
INTERVAL_MS="${INTERVAL_MS:-0}"

die() {
  echo "$1" >&2
  exit 1
}

require_darwin() {
  [[ "$(uname -s)" == Darwin ]] || die "PLACEMENT_FAILED: $(uname -s), not Darwin"
  command -v xcrun >/dev/null || die "PLACEMENT_FAILED: xcrun missing"
  xcodebuild -version >/dev/null 2>&1 || die "PLACEMENT_FAILED: xcodebuild missing"
}

begin() {
  require_darwin
  local dir="${1:-}"
  [[ -n "$dir" ]] || dir="$(mktemp -d /tmp/ios-save-tile.XXXXXX)"
  mkdir -p "$dir/frames"
  python3 -c 'import time; print(f"{time.time():.6f}")' >"$dir/t0.txt"
  echo "$dir"
}

capture() {
  require_darwin
  local dir="${1:-}"
  [[ -n "$dir" && -f "$dir/t0.txt" ]] || die "usage: capture DIR (from begin)"
  local t0
  t0="$(cat "$dir/t0.txt")"
  local i=0
  local now elapsed
  : >"$dir/times.tsv"
  while true; do
    xcrun simctl io booted screenshot "$dir/frames/$(printf '%03d' "$i").png" >/dev/null
    now="$(python3 -c 'import time; print(f"{time.time():.6f}")')"
    elapsed="$(python3 -c "print(int(($now - $t0) * 1000))")"
    printf '%03d\t%s\t%s\n' "$i" "$now" "$elapsed" >>"$dir/times.tsv"
    if (( elapsed > MAX_MS )); then
      break
    fi
    i=$((i + 1))
    python3 -c "import time; time.sleep($INTERVAL_MS / 1000)"
  done
  echo "frames=$i dir=$dir" >&2
}

score() {
  require_darwin
  local dir="${1:-}"
  [[ -n "$dir" && -f "$dir/times.tsv" ]] || die "usage: score DIR"
  [[ -x "$OCR" || -f "$OCR" ]] || die "missing $OCR"
  local needle
  needle="$(printf '%s' "$NEEDLE" | tr '[:upper:]' '[:lower:]')"
  local idx path stamp elapsed text lowered
  while IFS=$'\t' read -r idx stamp elapsed; do
    path="$dir/frames/${idx}.png"
    [[ -f "$path" ]] || continue
    text="$(swift "$OCR" "$path" 2>/dev/null || true)"
    lowered="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"
    # The Add card sheet sits on Rewards, so OCR can see the nav title plus the
    # selected HowMuch card name before Save has landed. Skip editor frames.
    if grep -Fq "$needle" <<<"$lowered" && grep -Fq "rewards" <<<"$lowered" && ! grep -Fq "existing howmuch card" <<<"$lowered"; then
      echo "$elapsed"
      printf '%s\n' "$text" >"$dir/hit.txt"
      echo "$idx" >"$dir/hit-frame.txt"
      cp "$path" "$dir/hit.png"
      return 0
    fi
  done <"$dir/times.tsv"
  die "no frame showed '$NEEDLE' on Rewards within ${MAX_MS} ms"
}

usage() {
  cat <<'EOF'
apps/ios/scripts/rewards-save-to-tile-clock.sh — Darwin save-to-tile clock

Fill Add card first. Then:

  DIR=$(apps/ios/scripts/rewards-save-to-tile-clock.sh begin)
  # tap Save immediately (cliclick or a single axe tap, not describe-ui)
  apps/ios/scripts/rewards-save-to-tile-clock.sh capture "$DIR"
  apps/ios/scripts/rewards-save-to-tile-clock.sh score "$DIR"

score prints elapsed ms for the first simctl frame whose OCR contains
"Travel Card" and "Rewards" and does not contain "Existing HowMuch card" (the Add card
editor). Median of three samples must be ≤800.
EOF
}

cmd="${1:-}"
case "$cmd" in
  begin) begin "${2:-}" ;;
  capture) capture "${2:-}" ;;
  score) score "${2:-}" ;;
  -h|--help|"") usage ;;
  *) die "unknown command: $cmd" ;;
esac
