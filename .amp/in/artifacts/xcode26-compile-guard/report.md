# Xcode 26 compile guard for `TabRole.prominent` (issue #280)

Base revision: `main` at `d35b664`, with the `#if compiler(>=6.4)` guard in `apps/ios/HowMuch/Views/Components.swift` applied as an uncommitted local patch. Run on a Devin macOS session (Darwin 25.6.0, arm64) on 2026-10-10. Nothing was pushed, signed or uploaded from that machine.

## Commands

```
scripts/ios-xcodebuild.sh test                      # Xcode 26.6 default
DEVELOPER_DIR=/Applications/Xcode-27.0-RC.app/Contents/Developer \
  scripts/ios-xcodebuild.sh test                    # iOS 27.0 simulator pinned via SIMULATOR_UDID, separate HOWMUCH_SIM_DERIVED
```

## Toolchains

| Xcode | Swift | Simulator |
|---|---|---|
| 26.6 (17F113) | 6.3.3 | iPhone 17, iOS 26.5 |
| 27.0 RC (27A266a) | 6.4 | iPhone 17, iOS 27.0 |

## Expected versus observed

| Expected | Observed | Result |
|---|---|---|
| Xcode 26.6 on unpatched `d35b664` reproduces #280 | `Components.swift:865:15: error: type 'TabRole' has no member 'prominent'`; build-for-testing exit=65 | Reproduced |
| Xcode 26.6 with guard builds and tests pass | build-for-testing exit=0; 871 executed, 2 skipped, 0 failed; 3 Swift Testing tests passed | Pass |
| Xcode 27.0 RC with guard builds and tests pass | build-for-testing exit=0; 871 executed, 2 skipped, 0 failed; 3 Swift Testing tests passed | Pass |
| `.prominent` branch still compiles on Xcode 27 | Temporary `#warning` inside the `#if` block fired at `Components.swift:865:14` (removed afterwards) | Pass |

The first patched Xcode 26 run had 6 `CaptureSnapshotTests` failures with empty accessibility labels, the freshly booted simulator issue described in `apps/ios/AGENTS.md`. After enabling simulator accessibility as that file describes, the rerun had 0 failures. The 2 skips are the env-gated live model and local screenshot tests.

Full log: Devin session `6c29c86d3f0a49feb5e970f03fc6346e`.
