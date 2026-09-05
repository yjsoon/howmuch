# Xcode validation

Use the published personal skill `validating-xcode-runners` for Xcode, iOS, and iPadOS validation. Run commands from the repository root, with one validation owner per Mac and checkout.

- Project: `apps/ios/HowMuch.xcodeproj` (there is no separate app workspace)
- Scheme: `HowMuch`
- Simulator destination: `platform=iOS Simulator,id=$SIMULATOR_UDID`
- Simulator DerivedData: `build/xcode/DerivedData-simulator`
- Device DerivedData: `build/xcode/DerivedData-device`
- Archive DerivedData: `build/xcode/DerivedData-archive`
- Logs: `build/xcode/logs`

Do not hard-code a simulator UDID: runner inventories are not shared. Set `SIMULATOR_UDID` to one available iPhone or iPad simulator running iOS 26 or later (`xcrun simctl list devices available`), preferring an already booted device, and use the same value for both commands below. Preserve timestamped logs and the pipeline status:

```sh
mkdir -p build/xcode/logs
stamp=$(date +%Y%m%d-%H%M%S)
set -o pipefail
xcodebuild -project apps/ios/HowMuch.xcodeproj -scheme HowMuch -sdk iphonesimulator -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" -derivedDataPath build/xcode/DerivedData-simulator -jobs 2 COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build-for-testing 2>&1 | tee "build/xcode/logs/${stamp}-build-for-testing.log"

stamp=$(date +%Y%m%d-%H%M%S)
xcodebuild -project apps/ios/HowMuch.xcodeproj -scheme HowMuch -sdk iphonesimulator -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" -derivedDataPath build/xcode/DerivedData-simulator -jobs 2 COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO test-without-building 2>&1 | tee "build/xcode/logs/${stamp}-test-without-building.log"
```

For an unsigned device-architecture build, use the separate device cache:

```sh
mkdir -p build/xcode/logs
stamp=$(date +%Y%m%d-%H%M%S); set -o pipefail
xcodebuild -project apps/ios/HowMuch.xcodeproj -scheme HowMuch -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath build/xcode/DerivedData-device -jobs 2 COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build 2>&1 | tee "build/xcode/logs/${stamp}-device-build.log"
```

For a signed archive and ad hoc export, follow the root `AGENTS.md` Speedflight preflight and use the repository-owned command `scripts/speedflight.sh "<one-line title>" "<what changed and what to test>"`; it owns the canonical signing/archive arguments and writes under the gitignored `build/` tree. Do not substitute unsigned archive commands, change signing, or reuse simulator/device caches for archive work.
