# Xcode validation

Use `scripts/ios-xcodebuild.sh` from the repository root. One validation owner per Mac and checkout. Local validation uses the intended worktree, including authorized local fixes; it needs no clean/pushed HEAD or signing secrets. Continue relevant fix/test/rerun loops within scope, but preserve an exact requested revision. Do not install `validating-xcode-runners` as a prerequisite.

- Project: `apps/ios/HowMuch.xcodeproj` (there is no separate app workspace)
- Scheme: `HowMuch`
- Simulator destination: `platform=iOS Simulator,id=$SIMULATOR_UDID`
- Simulator DerivedData: `build/xcode/DerivedData-simulator`
- Device DerivedData: `build/xcode/DerivedData-device`
- Archive DerivedData: `build/xcode/DerivedData-archive`
- Logs: `build/xcode/logs`

Do not hard-code a simulator UDID: runner inventories are not shared. The wrapper pins one available iOS 26+ simulator (prefer a booted iPhone, HowMuch Verification when present) and reuses that UDID for build, test, install, and launch. Override with `SIMULATOR_UDID` when you need a specific device, including iPad. After source changes use `test`, not `test-without-building`; never test stale products after a failed build. Select relevant tests/UI recipes for the task rather than every feature recipe.

The wrapper signs simulator builds ad hoc (`CODE_SIGN_IDENTITY=-`, no certificate or profile) so the test host has the simulated entitlements the real Keychain test needs; `HOWMUCH_SIM_SIGNING=unsigned` opts out. Details: [Simulator Keychain validation](../../docs/ai-providers.md#simulator-keychain-validation).

```sh
scripts/ios-xcodebuild.sh test
UDID="$(scripts/ios-xcodebuild.sh destination)"
xcrun simctl install "$UDID" "$(scripts/ios-xcodebuild.sh app-path)"
```

That is `build-for-testing` then `test-without-building` with the same destination and simulator cache. `test` runs `build-for-testing` every time, even when products exist; xcodebuild's incremental build is cheap when nothing changed. If the build fails, `test` exits non-zero without running tests.

Tell a fresh run from a stale one before trusting an unexpected pass or failure:

- Fresh (`test`): the console shows `runner: build-for-testing finished … exit=0` and `runner: build-for-testing succeeded; products match this worktree` before `runner: start test-without-building`. In `build/xcode/logs`, an `xcodebuild-build-for-testing-*.log` ending `exit=0` sits just before the matching `xcodebuild-test-without-building-*.log`.
- Stale (`test-without-building`): it reruns existing products deliberately and warns with the time `HowMuchTests` was last linked. Edits after that time are not under test. `doctor` prints the same time. A no-op incremental build does not relink, so on a fresh run that time can predate the run.
- Suspect: a test log with no successful build-for-testing log before it, or a run that reports 0 tests. Rerun with `test`.

A quiet console is not a hang: watch the heartbeat, inspect `actool` / `ibtoold` / `AssetCatalogSimulatorAgent` / `swift-frontend`, and allow 15 minutes on a cold medium build before terminating. Parent CPU near zero is not sufficient. Do not redirect `xcodebuild` to `/dev/null`. Do not clear DerivedData as a first response.

The snapshot harness (`SnapshotSurface` in `CaptureSnapshotTests.swift`) reads SwiftUI accessibility elements, which a newly created simulator does not expose: every lookup comes back empty and the Capture suites fail with `accessibilityLabels() == []`. Enable accessibility once per simulator:

```sh
xcrun simctl spawn "$UDID" defaults write com.apple.Accessibility AccessibilityEnabled -bool true
xcrun simctl spawn "$UDID" defaults write com.apple.Accessibility ApplicationAccessibilityEnabled -bool true
```

When device-architecture coverage is relevant, use this unsigned Debug build and separate device cache. It does not sign, install, or prove physical-device behavior:

```sh
mkdir -p build/xcode/logs
stamp=$(date +%Y%m%d-%H%M%S); set -o pipefail
xcodebuild -project apps/ios/HowMuch.xcodeproj -scheme HowMuch -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath build/xcode/DerivedData-device -jobs 2 COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build 2>&1 | tee "build/xcode/logs/${stamp}-device-build.log"
```

Signed archive/export/publication requires explicit authorization and [Speedflight preflight](../../docs/speedflight.md). The repository-owned `scripts/speedflight.sh` owns canonical signing/archive arguments, uses `build/xcode/DerivedData-archive`, and uploads in the same invocation; it is not a local validation command. Increment every `CURRENT_PROJECT_VERSION` in `HowMuch.xcodeproj/project.pbxproj` before the cut so the phone replaces the last IPA. Do not substitute unsigned archives, change signing, reuse simulator/device caches for archives, erase shared caches, or terminate another owner's work. Report test execution separately from compilation and physical-device installation.
