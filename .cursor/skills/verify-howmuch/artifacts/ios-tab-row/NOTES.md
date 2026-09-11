# iOS tab-row Add and Assistant

Date: 2026-09-11. Darwin `yjmbpro.local`, Xcode 26.6 (17F113).
Branch: `cursor/inline-tab-actions-467d` @ `f735493`.
Simulator: HowMuch Verification `BA2CAD1A-0977-4290-8486-760091B333AE` (iOS 26.5).
API: `http://127.0.0.1:60500`. Never `howmuch.soon.sg`.
Signed in as `verifier`. Plan HowMuch Demo.

## Tests

`build-for-testing` then:

- `HowMuchTests/CaptureSnapshotTests/testTabRowAddTapAndAccessibilityActionUseDistinctRoutes`
- `HowMuchTests/IPadLayoutTests/testCompactRootTabViewRendersThreeTabs`
- `HowMuchTests/IPadLayoutTests/testSidebarRootTabViewDoesNotInstallTabRowAssistant`

Executed 3 tests, 0 failures.

## Drive

Compact iPhone: Accounts / Rewards / Reflect sit in the search-role tab capsule. Assistant is a peer circle immediately leading the Add pin. No 56pt FAB above the bar. Assistant does not cover Add.

- `accounts.png` / `rewards.png` / `reflect.png`: tab row on each root tab after sign-in.
- Tap Add (search-role plus): `add-capture.png` is **Add Transactions**. Close. `after-close-reflect.png` still has Reflect selected — capture does not change the tab.
- Tap Assistant: `assistant.png` opens Assistant from the row, not only from More.

Live physical iPhone was not driven. Simulator is the proof on this host.

The Assistant overlay stays window-hosted while Add Transactions is up, so the chat circle can draw over the composer. That is overlay tightness leftover from `f735493`, not a tab-selection miss.
