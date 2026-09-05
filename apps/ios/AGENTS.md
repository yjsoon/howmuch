# Xcode validation

Use `validating-xcode-runners` when available; do not install it as a prerequisite to the safe local commands below. Run from the repository root, with one validation owner per Mac and checkout. Local validation uses the intended worktree, including authorized local fixes; it needs no clean/pushed HEAD or signing secrets. Continue relevant fix/test/rerun loops within scope, but preserve an exact requested revision.

- Project: `apps/ios/HowMuch.xcodeproj` (there is no separate app workspace)
- Scheme: `HowMuch`
- Simulator destination: `platform=iOS Simulator,id=$SIMULATOR_UDID`
- Simulator DerivedData: `build/xcode/DerivedData-simulator`
- Device DerivedData: `build/xcode/DerivedData-device`
- Archive DerivedData: `build/xcode/DerivedData-archive`
- Logs: `build/xcode/logs`

Do not hard-code a simulator UDID: runner inventories are not shared. Set `SIMULATOR_UDID` to one available iPhone or iPad simulator running iOS 26 or later (`xcrun simctl list devices available`), preferring an already booted device, and use it for both phases and any simulator install/launch. The Bash subshell stops on a failed phase and preserves pipeline status. Rebuild after source changes; never test stale products after a failed build. Select relevant tests/UI recipes for the task rather than every feature recipe.

```sh
(
set -euo pipefail
: "${SIMULATOR_UDID:?select an available iOS 26+ simulator}"
mkdir -p build/xcode/logs
stamp=$(date +%Y%m%d-%H%M%S)
xcodebuild -project apps/ios/HowMuch.xcodeproj -scheme HowMuch -sdk iphonesimulator -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" -derivedDataPath build/xcode/DerivedData-simulator -jobs 2 COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build-for-testing 2>&1 | tee "build/xcode/logs/${stamp}-build-for-testing.log"

stamp=$(date +%Y%m%d-%H%M%S)
xcodebuild -project apps/ios/HowMuch.xcodeproj -scheme HowMuch -sdk iphonesimulator -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" -derivedDataPath build/xcode/DerivedData-simulator -jobs 2 COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO test-without-building 2>&1 | tee "build/xcode/logs/${stamp}-test-without-building.log"
)
```

When device-architecture coverage is relevant, use this unsigned Debug build and separate device cache. It does not sign, install, or prove physical-device behavior:

```sh
mkdir -p build/xcode/logs
stamp=$(date +%Y%m%d-%H%M%S); set -o pipefail
xcodebuild -project apps/ios/HowMuch.xcodeproj -scheme HowMuch -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath build/xcode/DerivedData-device -jobs 2 COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build 2>&1 | tee "build/xcode/logs/${stamp}-device-build.log"
```

Signed archive/export/publication requires explicit authorization and [Speedflight preflight](../../docs/speedflight.md). The repository-owned `scripts/speedflight.sh` owns canonical signing/archive arguments and uploads in the same invocation; it is not a local validation command. Do not substitute unsigned archives, change signing, reuse simulator/device caches for archives, erase shared caches, or terminate another owner's work. Report test execution separately from compilation and physical-device installation.
