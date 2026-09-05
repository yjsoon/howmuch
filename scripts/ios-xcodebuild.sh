#!/usr/bin/env bash
# Agent/CLI xcodebuild for HowMuch. Standing policy lives in
# apps/ios/AGENTS.md. This script is the mechanical half: one owner per
# checkout, a pinned simulator UDID, a stable gitignored DerivedData path,
# a low job count with indexing off, and timestamped logs.
#
# Do not clear DerivedData as a first response. Do not cancel merely
# because xcodebuild looks idle — inspect children (actool, ibtoold,
# AssetCatalogSimulatorAgent, swift-frontend) first. Cold builds may
# stay quiet for minutes on a 16 GB Mac.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PROJECT="apps/ios/HowMuch.xcodeproj"
SCHEME="HowMuch"
SIM_DERIVED="${HOWMUCH_SIM_DERIVED:-$ROOT/build/xcode/DerivedData-simulator}"
ARCHIVE_DERIVED="${HOWMUCH_ARCHIVE_DERIVED:-$ROOT/build/xcode/DerivedData-archive}"
LOG_DIR="${HOWMUCH_XCODE_LOG_DIR:-$ROOT/build/xcode/logs}"
LOCK_DIR="${HOWMUCH_XCODE_LOCK_DIR:-$ROOT/build/xcode/ios-xcodebuild.lock}"
STATE_FILE="$SIM_DERIVED/runner-state"
JOBS="${HOWMUCH_XCODE_JOBS:-2}"
HEARTBEAT_SECS="${HOWMUCH_XCODE_HEARTBEAT_SECS:-30}"

usage() {
  cat <<'EOF'
scripts/ios-xcodebuild.sh — HowMuch agent/CLI xcodebuild

Usage:
  scripts/ios-xcodebuild.sh doctor
  scripts/ios-xcodebuild.sh build [--generic]
  scripts/ios-xcodebuild.sh build-for-testing
  scripts/ios-xcodebuild.sh test-without-building [-- extra xcodebuild args]
  scripts/ios-xcodebuild.sh test [-- extra xcodebuild args]
  scripts/ios-xcodebuild.sh app-path
  scripts/ios-xcodebuild.sh destination

Environment:
  SIMULATOR_UDID / HOWMUCH_SIM_UDID / HOWMUCH_SIM_DEVICE
                                      pin destination (UDID preferred)
  HOWMUCH_SIM_DERIVED                 default build/xcode/DerivedData-simulator
  HOWMUCH_ARCHIVE_DERIVED             default build/xcode/DerivedData-archive
  HOWMUCH_XCODE_JOBS                  default 2 (tunable, not a universal optimum)
  HOWMUCH_XCODE_HEARTBEAT_SECS        default 30
  HOWMUCH_SHUTDOWN_OTHER_SIMULATORS=1 shut down booted sims that are not the pin

Examples:
  scripts/ios-xcodebuild.sh build
  scripts/ios-xcodebuild.sh test -- -only-testing:HowMuchTests
EOF
}

need_darwin() {
  if [[ "$(uname)" != Darwin ]]; then
    echo "error: iOS xcodebuild only runs on a Mac with Xcode" >&2
    exit 1
  fi
  if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "error: xcodebuild not on PATH" >&2
    exit 1
  fi
}

mkdir_build() {
  mkdir -p "$SIM_DERIVED" "$ARCHIVE_DERIVED" "$LOG_DIR" "$(dirname "$LOCK_DIR")"
}

pressure_line() {
  local level swap
  level="$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || echo "?")"
  swap="$(sysctl vm.swapusage 2>/dev/null | sed -E 's/^vm.swapusage: //' || true)"
  printf 'memory_pressure=%s swap=%s' "$level" "$swap"
}

booted_simulator_lines() {
  xcrun simctl list devices booted 2>/dev/null | awk '/\([A-F0-9-]{36}\)/ {print}' || true
}

competing_xcodebuild() {
  pgrep -lf xcodebuild 2>/dev/null | grep -v "ios-xcodebuild.sh" || true
}

acquire_lock() {
  local i other
  for i in 1 2 3; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      printf '%s\n' "$$" >"$LOCK_DIR/pid"
      trap release_lock EXIT
      return 0
    fi
    other="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [[ -n "$other" ]] && kill -0 "$other" 2>/dev/null; then
      echo "error: another HowMuch xcodebuild owns this checkout (pid $other)" >&2
      echo "Give one agent ownership of Xcode validation per Mac/checkout." >&2
      exit 75
    fi
    echo "warning: stale lock at $LOCK_DIR (pid ${other:-unknown}); reclaiming" >&2
    rm -rf "$LOCK_DIR"
  done
  echo "error: could not acquire $LOCK_DIR" >&2
  exit 75
}

release_lock() {
  if [[ -d "$LOCK_DIR" ]]; then
    local owner
    owner="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [[ "$owner" == "$$" ]]; then
      rm -rf "$LOCK_DIR"
    fi
  fi
}

resolve_destination() {
  python3 - "$STATE_FILE" "${HOWMUCH_SIM_UDID:-${SIMULATOR_UDID:-}}" "${HOWMUCH_SIM_DEVICE:-}" <<'PY'
import json, re, subprocess, sys

state_path, env_udid, env_name = sys.argv[1:4]
saved_udid = ""
try:
    saved_udid = open(state_path).read().strip()
except FileNotFoundError:
    pass

raw = subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"])
data = json.loads(raw)
all_ios = []
for runtime, devices in data.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    m = re.search(r"\.iOS-(\d+(?:-\d+)*)$", runtime)
    ios = tuple(int(p) for p in m.group(1).split("-")) if m else (0,)
    for device in devices:
        if not device.get("isAvailable", True):
            continue
        name = device.get("name", "")
        dtype = device.get("deviceTypeIdentifier", "")
        is_ipad = "iPad" in name or "iPad" in dtype
        is_iphone = "iPhone" in name or "iPhone" in dtype
        if not is_ipad and not is_iphone:
            continue
        all_ios.append(
            {
                "ios": ios,
                "name": name,
                "udid": device["udid"],
                "state": device.get("state", ""),
                "howmuch": "howmuch" in name.lower(),
                "iphone": is_iphone and not is_ipad,
            }
        )

if not all_ios:
    sys.stderr.write("error: no available iOS simulator\n")
    sys.exit(1)

by_udid = {p["udid"]: p for p in all_ios}
by_name = {}
for p in all_ios:
    by_name.setdefault(p["name"], p)
phones = [p for p in all_ios if p["iphone"]]

chosen = None
if env_udid:
    chosen = by_udid.get(env_udid)
    if chosen is None:
        sys.stderr.write(f"error: SIMULATOR_UDID {env_udid} is not an available iOS simulator\n")
        sys.exit(1)
elif env_name:
    chosen = by_name.get(env_name)
    if chosen is None:
        sys.stderr.write(f"error: HOWMUCH_SIM_DEVICE {env_name!r} is not an available iOS simulator\n")
        sys.exit(1)
elif saved_udid and saved_udid in by_udid:
    chosen = by_udid[saved_udid]
else:
    pool = phones or all_ios
    pool.sort(
        key=lambda p: (
            p["howmuch"],
            p["state"] == "Booted",
            p["ios"],
            p["name"],
        ),
        reverse=True,
    )
    chosen = pool[0]

print(f"{chosen['udid']}|{chosen['name']}")
PY
}

load_destination() {
  local generic="${1:-0}"
  if [[ "$generic" == 1 ]]; then
    DEST_SPEC='generic/platform=iOS Simulator'
    DEST_UDID=""
    DEST_NAME="generic iOS Simulator"
    return 0
  fi
  local resolved
  resolved="$(resolve_destination)"
  DEST_UDID="${resolved%%|*}"
  DEST_NAME="${resolved#*|}"
  DEST_SPEC="platform=iOS Simulator,id=$DEST_UDID"
  printf '%s\n' "$DEST_UDID" >"$STATE_FILE"
}

maybe_shutdown_other_simulators() {
  [[ "${HOWMUCH_SHUTDOWN_OTHER_SIMULATORS:-}" == 1 ]] || return 0
  [[ -n "${DEST_UDID:-}" ]] || return 0
  local line udid name
  while IFS= read -r line; do
    udid="$(sed -nE 's/.*\(([A-F0-9-]{36})\).*/\1/p' <<<"$line")"
    name="$(sed -nE 's/^[[:space:]]*(.*) \([A-F0-9-]{36}\).*/\1/p' <<<"$line")"
    if [[ -n "$udid" && "$udid" != "$DEST_UDID" ]]; then
      echo "shutting down unrelated simulator: $name ($udid)"
      xcrun simctl shutdown "$udid" >/dev/null || true
    fi
  done < <(booted_simulator_lines)
}

warn_host() {
  local others
  echo "runner: jobs=$JOBS COMPILER_INDEX_STORE_ENABLE=NO destination=$DEST_SPEC"
  echo "runner: derivedData=$SIM_DERIVED"
  echo "runner: $(pressure_line)"
  others="$(booted_simulator_lines)"
  if [[ -n "$others" ]]; then
    echo "runner: booted simulators:"
    echo "$others" | sed 's/^/  /'
  fi
  local competing
  competing="$(competing_xcodebuild)"
  if [[ -n "$competing" ]]; then
    echo "warning: other xcodebuild processes are running; avoid concurrent builds" >&2
    echo "$competing" | sed 's/^/  /' >&2
  fi
  local level
  level="$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || echo 0)"
  if [[ "$level" =~ ^[0-9]+$ ]] && ((level >= 2)); then
    echo "warning: memory pressure $level with heavy swap. Prefer one Xcode owner, jobs=$JOBS, and no concurrent archives or extra simulators." >&2
  fi
}

common_settings() {
  XCODE_SETTINGS=(
    CODE_SIGNING_ALLOWED=NO
    COMPILER_INDEX_STORE_ENABLE=NO
    ONLY_ACTIVE_ARCH=YES
    ARCHS=arm64
    EXCLUDED_ARCHS=x86_64
    CLANG_MODULE_CACHE_PATH="$SIM_DERIVED/ModuleCache"
    SWIFT_MODULECACHE_PATH="$SIM_DERIVED/ModuleCache"
  )
}

stamp_log() {
  local action="$1"
  printf '%s/xcodebuild-%s-%s.log' "$LOG_DIR" "$action" "$(date '+%Y%m%d-%H%M%S')"
}

start_heartbeat() {
  local xcode_pid="$1"
  local start_ts="$2"
  (
    while kill -0 "$xcode_pid" 2>/dev/null; do
      sleep "$HEARTBEAT_SECS"
      kill -0 "$xcode_pid" 2>/dev/null || break
      local elapsed=$(( $(date +%s) - start_ts ))
      echo "runner: heartbeat t=${elapsed}s pid=$xcode_pid $(pressure_line)"
      ps -o pid=,pcpu=,pmem=,etime=,comm= -p "$xcode_pid" 2>/dev/null | sed 's/^/runner:   xcodebuild /' || true
      pgrep -lf 'actool|ibtoold|AssetCatalogSimulatorAgent|swift-frontend|swift-plugin-server' 2>/dev/null \
        | awk 'NR<=8 {print "runner:   child " $0}' || true
    done
  ) &
  HEARTBEAT_PID=$!
}

stop_heartbeat() {
  if [[ -n "${HEARTBEAT_PID:-}" ]]; then
    kill "$HEARTBEAT_PID" 2>/dev/null || true
    wait "$HEARTBEAT_PID" 2>/dev/null || true
    HEARTBEAT_PID=""
  fi
}

run_xcodebuild_with_heartbeat() {
  local action="$1"
  shift
  local log
  log="$(stamp_log "$action")"
  local start_ts start_iso
  start_ts="$(date +%s)"
  start_iso="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  echo "runner: start $action at $start_iso"
  echo "runner: log $log"
  echo "runner: allow 15+ minutes for a cold build before diagnosing a stall"
  {
    echo "=== start $start_iso action=$action ==="
    echo "=== cwd=$ROOT ==="
    echo "=== destination=$DEST_SPEC derivedData=$SIM_DERIVED jobs=$JOBS ==="
    echo "=== $(pressure_line) ==="
    echo "=== argv: xcodebuild $* ==="
  } | tee "$log"

  set +e
  tail -n 0 -f "$log" &
  local tail_pid=$!
  xcodebuild "$@" >>"$log" 2>&1 &
  local xcode_pid=$!
  start_heartbeat "$xcode_pid" "$start_ts"
  wait "$xcode_pid"
  local status=$?
  stop_heartbeat
  kill "$tail_pid" 2>/dev/null || true
  wait "$tail_pid" 2>/dev/null || true
  set -e

  local end_iso elapsed
  end_iso="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  elapsed=$(( $(date +%s) - start_ts ))
  {
    echo "=== end $end_iso elapsed=${elapsed}s exit=$status ==="
    echo "=== $(pressure_line) ==="
  } | tee -a "$log"
  echo "runner: $action finished in ${elapsed}s exit=$status"
  return "$status"
}

app_path() {
  printf '%s/Build/Products/Debug-iphonesimulator/HowMuch.app\n' "$SIM_DERIVED"
}

test_product_exists() {
  local app xctest
  app="$(app_path)"
  xctest="$SIM_DERIVED/Build/Products/Debug-iphonesimulator/HowMuchTests.xctest"
  [[ -d "$app" && -d "$xctest" ]]
}

cmd_doctor() {
  need_darwin
  mkdir_build
  load_destination 0
  echo "xcode: $(xcodebuild -version | tr '\n' ' ')"
  echo "destination: $DEST_NAME ($DEST_UDID)"
  echo "sim derivedData: $SIM_DERIVED"
  echo "archive derivedData: $ARCHIVE_DERIVED"
  echo "logs: $LOG_DIR"
  echo "jobs: $JOBS (COMPILER_INDEX_STORE_ENABLE=NO)"
  echo "lock: $([[ -d "$LOCK_DIR" ]] && echo held by "$(cat "$LOCK_DIR/pid" 2>/dev/null || echo unknown)" || echo free)"
  echo "app: $(app_path) $([[ -d "$(app_path)" ]] && echo present || echo missing)"
  echo "tests: $([[ -d "$SIM_DERIVED/Build/Products/Debug-iphonesimulator/HowMuchTests.xctest" ]] && echo present || echo missing)"
  echo "$(pressure_line)"
  echo "booted simulators:"
  local booted
  booted="$(booted_simulator_lines)"
  if [[ -z "$booted" ]]; then
    echo "  (none)"
  else
    echo "$booted" | sed 's/^/  /'
  fi
  local competing
  competing="$(competing_xcodebuild)"
  if [[ -n "$competing" ]]; then
    echo "other xcodebuild:"
    echo "$competing" | sed 's/^/  /'
  else
    echo "other xcodebuild: none"
  fi
}

cmd_destination() {
  need_darwin
  mkdir_build
  load_destination 0
  printf '%s\n' "$DEST_UDID"
  echo "$DEST_NAME" >&2
}

cmd_app_path() {
  mkdir_build
  app_path
}

prepare_build() {
  local generic="${1:-0}"
  need_darwin
  mkdir_build
  acquire_lock
  load_destination "$generic"
  maybe_shutdown_other_simulators
  warn_host
  common_settings
}

xcode_invocation() {
  local action="$1"
  shift
  local dest="$DEST_SPEC"
  run_xcodebuild_with_heartbeat "$action" \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -sdk iphonesimulator \
    -destination "$dest" \
    -derivedDataPath "$SIM_DERIVED" \
    -jobs "$JOBS" \
    -showBuildTimingSummary \
    "${XCODE_SETTINGS[@]}" \
    "$@"
}

cmd_build() {
  local generic=0
  if [[ "${1:-}" == --generic ]]; then
    generic=1
    shift
  fi
  prepare_build "$generic"
  xcode_invocation build build
}

cmd_build_for_testing() {
  prepare_build 0
  xcode_invocation build-for-testing build-for-testing
}

cmd_test_without_building() {
  prepare_build 0
  if ! test_product_exists; then
    echo "error: no test products in $SIM_DERIVED; run build-for-testing first" >&2
    exit 1
  fi
  xcode_invocation test-without-building test-without-building "$@"
}

cmd_test() {
  prepare_build 0
  if ! test_product_exists; then
    echo "runner: no test products yet; build-for-testing once, then test-without-building"
    xcode_invocation build-for-testing build-for-testing
  fi
  xcode_invocation test-without-building test-without-building "$@"
}

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    doctor) cmd_doctor ;;
    destination) cmd_destination ;;
    app-path) cmd_app_path ;;
    build) cmd_build "$@" ;;
    build-for-testing) cmd_build_for_testing "$@" ;;
    test-without-building)
      if [[ "${1:-}" == -- ]]; then shift; fi
      cmd_test_without_building "$@"
      ;;
    test)
      if [[ "${1:-}" == -- ]]; then shift; fi
      cmd_test "$@"
      ;;
    -h|--help|help|"") usage ;;
    *)
      echo "error: unknown command $cmd" >&2
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
