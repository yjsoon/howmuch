#!/bin/zsh
# NOT FOR MERGING. Runs the real-tap payee picker harness (HowMuchUITests).
# usage:
#   SIMULATOR_UDID=<udid> docs/repro/payee-picker/uitest.sh build
#   SIMULATOR_UDID=<udid> TEST_RUNNER_REPRO_...=... docs/repro/payee-picker/uitest.sh test -only-testing:HowMuchUITests/PayeePickerRealTapUITests/<test>
# REPRO_* settings reach the test runner through the TEST_RUNNER_ prefix.
set -o pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
U="${SIMULATOR_UDID:?set SIMULATOR_UDID}"
D="$ROOT/build/xcode/DerivedData-simulator"
OUT="${REPRO_OUT:-$ROOT/build/xcode/repro}"
action=$1; shift
case $action in
  build) act=build-for-testing ;;
  test) act=test-without-building ;;
  *) echo "usage: $0 build|test [xcodebuild args]" >&2; exit 2 ;;
esac
stamp=$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"
extra=()
[[ $act == test-without-building ]] && extra=(-resultBundlePath "$OUT/$stamp.xcresult" -collect-test-diagnostics never)
xcodebuild $act -project "$ROOT/apps/ios/HowMuch.xcodeproj" -scheme HowMuchUITests -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$U" -derivedDataPath "$D" -jobs 2 \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_STYLE=Manual \
  PROVISIONING_PROFILE= PROVISIONING_PROFILE_SPECIFIER= COMPILER_INDEX_STORE_ENABLE=NO ONLY_ACTIVE_ARCH=YES \
  ARCHS=arm64 EXCLUDED_ARCHS=x86_64 CLANG_MODULE_CACHE_PATH="$D/ModuleCache" SWIFT_MODULECACHE_PATH="$D/ModuleCache" \
  "${extra[@]}" "$@" > "$OUT/uitest-$stamp.log" 2>&1
grep -E "REPRO|error:|\*\* " "$OUT/uitest-$stamp.log" | grep -v " t = "
echo "log: $OUT/uitest-$stamp.log"
