# Thermos findings log

Started: 2026-09-13 ~00:40 UTC
Run: [Thermos functionality](https://cursor.com/agents/bc-262475ab-e4b4-4bda-a645-9c366d940445)
Repo: `yjsoon/howmuch`
This file: persist review progress if credits die. Single source of truth for this run.

## Status

- Review scope: **open PR #203** — `fix(ios): gate AccountsView split on iPad sidebar`
- PR: https://github.com/yjsoon/howmuch/pull/203
- Head: `cursor/first-launch-empty-sheet-8bbc` @ `860f213`
- Base: `main` @ `37bf864`
- +89 / −26 across 4 files, 4 commits
- Logging branch: `cursor/thermos-pr-203-0445`

## Timeline

- [x] Inspect git state
- [x] Identify run as "Thermos functionality"
- [x] Confirm review target: open PR #203
- [x] Gather full diff + changed file contents
- [ ] Launch thermo-nuclear-review-subagent
- [ ] Launch thermo-nuclear-code-quality-review-subagent
- [ ] Synthesize unified verdict

## Unified verdict

*(empty until both subagents return)*

## Findings (deduped)

*(empty until synthesis)*

---

## Notes as I go

### 2026-09-13 00:43 — context gathered

**Intent (from PR body):** A fresh iPhone install could present `No Transactions` without a tap. `AccountsView` treated any regular-width trait as an iPad split, pinned a register, and showed the empty `ContentUnavailableView` when the ledger had no snapshot yet. Root chrome already keeps the sidebar on iPad regular width only. Accounts now uses that same gate.

**Commits:**

1. `a1c90e2` test(ios): catch empty register on phone regular width
2. `0534109` fix(ios): gate AccountsView split on iPad sidebar
3. `b976dbb` fix(ios): compile CaptureSnapshotTests for Mac verify
4. `860f213` fix(ios): keep phone register across rotation

**Files:**

| File | Lines now | Was | Notes |
| --- | ---: | ---: | --- |
| `apps/ios/HowMuch/Views/AccountsView.swift` | 1253 | 1242 | already >1k; +11 |
| `apps/ios/HowMuch/Views/Components.swift` | 1242 | 1242 | already >1k; 2 call-site edits |
| `apps/ios/HowMuchTests/IPadLayoutTests.swift` | 557 | — | +2 tests, rename helpers |
| `apps/ios/HowMuchTests/CaptureSnapshotTests.swift` | 3300 | — | argument order + `throws` |

**Call sites of `AccountsView(` on the PR branch:**

- `Components.swift:473` `AccountsView(usesSplit: usesSidebar)` sidebar Tab
- `Components.swift:546` `AccountsView(usesSplit: usesSidebar)` compact destination
- `IPadLayoutTests.swift:12` `AccountsView(usesSplit: true)` split snapshot
- `IPadLayoutTests.swift:94` **`AccountsView()` with no override** (`testCompactAccountsStillPushesSingleColumn`)

**Canonical gate (unchanged):**

```swift
enum RootChrome {
  static func usesSidebar(
    idiom: UIUserInterfaceIdiom,
    horizontalSizeClass: UserInterfaceSizeClass?
  ) -> Bool {
    idiom == .pad && horizontalSizeClass == .regular
  }
}
```

`RootView` already passes `usesSidebar` into `RootTabView`. Production `AccountsView` now receives that same bool as `usesSplit`. Fallback if omitted: `RootChrome.usesSidebar(idiom: UIDevice.current.userInterfaceIdiom, horizontalSizeClass:)`.

**Parent observations (not yet verdicts — for reviewers to confirm or kill):**

1. `RootTabView` is `if usesSidebar { … } else { … }`, so switching idiom/size class **destroys** `AccountsView` and its `@State pane`. `onChange(of: isSplit)` / `afterSplitChange` may never fire on the production trees; slide-over would recreate the view with `pane == nil` then `onAppear` → `reconcilePane()`. Worth confirming whether `afterSplitChange` is live or vestigial.
2. Optional `usesSplit: Bool? = nil` is a second API next to `RootChrome.usesSidebar`. Compact test at line 94 still relies on the device-idiom fallback.
3. `CaptureSnapshotTests` edits (param order + `async throws`) are compile fixes, not the layout bug. `testPendingImageAndFinancialTextKeepSendEnabled` uses `try XCTUnwrap` so `throws` is real.
4. Empty-register snapshot hosts `RootTabView(usesSidebar: false)` at 844×390 with `.regular` size class — matches Plus/Max landscape.

### 2026-09-13 00:41 — review target locked

Open PR: https://github.com/yjsoon/howmuch/pull/203

Closed recently (not in scope):
- #202 Reflect sidebar collapse — already on main
- #201 CompactBarSelection
- #200 tab bar
- #199 AI add-transaction

### 2026-09-13 00:40 — git state

This VM was on `main` @ `37bf864`, clean working tree. No branch-vs-main diff on the agent checkout. Latest merged commit is Reflect sidebar collapse, already on main, not the live review target.

---

## Diff (PR #203 vs main)

```
diff --git a/apps/ios/HowMuch/Views/AccountsView.swift b/apps/ios/HowMuch/Views/AccountsView.swift
index d2e4af7..d633513 100644
--- a/apps/ios/HowMuch/Views/AccountsView.swift
+++ b/apps/ios/HowMuch/Views/AccountsView.swift
@@ -36,7 +36,7 @@ enum AccountsPane: Hashable, Identifiable {
 enum AccountsPaneSelection {
   static func reconciled(
     current: AccountsPane?,
-    isRegularWidth: Bool,
+    usesSplit: Bool,
     knownAccountIDs: Set<String>,
     canChooseDefault: Bool,
     defaultPane: AccountsPane
@@ -45,24 +45,27 @@ enum AccountsPaneSelection {
     if case .account(let id) = pane, !knownAccountIDs.contains(id) {
       pane = nil
     }
-    guard isRegularWidth else { return pane }
+    guard usesSplit else { return pane }
     if pane == nil, canChooseDefault {
       return defaultPane
     }
     return pane
   }

-  static func afterSizeClassChange(
+  /// Called when `AccountsView.isSplit` flips, not on every size-class change.
+  /// Phone Plus/Max rotation stays stacked (`usesSplit` false) and must keep a
+  /// user-pushed register; leaving split (iPad slide-over) clears the pane.
+  static func afterSplitChange(
     current: AccountsPane?,
-    isRegularWidth: Bool,
+    usesSplit: Bool,
     knownAccountIDs: Set<String>,
     canChooseDefault: Bool,
     defaultPane: AccountsPane
   ) -> AccountsPane? {
-    guard isRegularWidth else { return nil }
+    guard usesSplit else { return nil }
     return reconciled(
       current: current,
-      isRegularWidth: true,
+      usesSplit: true,
       knownAccountIDs: knownAccountIDs,
       canChooseDefault: canChooseDefault,
       defaultPane: defaultPane
@@ -74,16 +77,24 @@ struct AccountsView: View {
   @Environment(AppModel.self) private var model
   @Environment(\.dynamicTypeSize) private var dynamicTypeSize
   @Environment(\.horizontalSizeClass) private var horizontalSizeClass
+  var usesSplit: Bool? = nil
   @State private var collapsedGroups: Set<String> = ["closed"]
   @State private var presentedSheet: AccountsSheet?
   @State private var groupPendingDeletion: CustomAccountGroup?
   @State private var pane: AccountsPane?
   @State private var columnVisibility = NavigationSplitViewVisibility.all

+  private var isSplit: Bool {
+    usesSplit ?? RootChrome.usesSidebar(
+      idiom: UIDevice.current.userInterfaceIdiom,
+      horizontalSizeClass: horizontalSizeClass
+    )
+  }

   var body: some View {
     @Bindable var screenshots = ScreenshotOfferController.shared
     Group {
-      if horizontalSizeClass == .regular {
+      if isSplit {
         NavigationSplitView(columnVisibility: $columnVisibility) {
           overview(screenshots: screenshots)
             .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 420)
@@ -113,10 +124,10 @@ struct AccountsView: View {
     .onAppear {
       reconcilePane()
     }
-    .onChange(of: horizontalSizeClass) { _, _ in
-      pane = AccountsPaneSelection.afterSizeClassChange(
+    .onChange(of: isSplit) { _, _ in
+      pane = AccountsPaneSelection.afterSplitChange(
         current: pane,
-        isRegularWidth: horizontalSizeClass == .regular,
+        usesSplit: isSplit,
         knownAccountIDs: knownAccountIDs,
         canChooseDefault: canChooseDefaultPane,
         defaultPane: defaultPane
@@ -188,7 +199,7 @@ struct AccountsView: View {
   private func reconcilePane() {
     pane = AccountsPaneSelection.reconciled(
       current: pane,
-      isRegularWidth: horizontalSizeClass == .regular,
+      usesSplit: isSplit,
       knownAccountIDs: knownAccountIDs,
       canChooseDefault: canChooseDefaultPane,
       defaultPane: defaultPane
```

`Components.swift`: both `AccountsView()` sites become `AccountsView(usesSplit: usesSidebar)`.

`CaptureSnapshotTests.swift`: swap `forbidden` / `scanUntilExpectedTogether` argument order; mark `testPendingImageAndFinancialTextKeepSendEnabled` as `async throws`.

`IPadLayoutTests.swift`: force `usesSplit: true` on the iPad split snapshot; add `testPhoneRegularAccountsDoesNotPresentEmptyTransactionsSheet` and `testPhoneRegularWidthDoesNotAutoSelectRegisterPane`; rename pane helpers to `usesSplit` / `afterSplitChange`.

---

## Changed-file excerpts (PR tip)

### AccountsView.swift (selection + split gate)

```swift
enum AccountsPaneSelection {
  static func reconciled(
    current: AccountsPane?,
    usesSplit: Bool,
    knownAccountIDs: Set<String>,
    canChooseDefault: Bool,
    defaultPane: AccountsPane
  ) -> AccountsPane? {
    var pane = current
    if case .account(let id) = pane, !knownAccountIDs.contains(id) {
      pane = nil
    }
    guard usesSplit else { return pane }
    if pane == nil, canChooseDefault {
      return defaultPane
    }
    return pane
  }

  /// Called when `AccountsView.isSplit` flips, not on every size-class change.
  /// Phone Plus/Max rotation stays stacked (`usesSplit` false) and must keep a
  /// user-pushed register; leaving split (iPad slide-over) clears the pane.
  static func afterSplitChange(
    current: AccountsPane?,
    usesSplit: Bool,
    knownAccountIDs: Set<String>,
    canChooseDefault: Bool,
    defaultPane: AccountsPane
  ) -> AccountsPane? {
    guard usesSplit else { return nil }
    return reconciled(
      current: current,
      usesSplit: true,
      knownAccountIDs: knownAccountIDs,
      canChooseDefault: canChooseDefault,
      defaultPane: defaultPane
    )
  }
}

struct AccountsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  var usesSplit: Bool? = nil
  // ...
  private var isSplit: Bool {
    usesSplit ?? RootChrome.usesSidebar(
      idiom: UIDevice.current.userInterfaceIdiom,
      horizontalSizeClass: horizontalSizeClass
    )
  }
  var body: some View {
    Group {
      if isSplit {
        NavigationSplitView(...) { overview } detail: { ... }
      } else {
        NavigationStack {
          overview.navigationDestination(item: $pane) { ... }
        }
      }
    }
    .onAppear { reconcilePane() }
    .onChange(of: isSplit) { _, _ in
      pane = AccountsPaneSelection.afterSplitChange(... usesSplit: isSplit ...)
    }
    .onChange(of: model.accounts.map(\.id)) { _, _ in reconcilePane() }
    .onChange(of: model.referencePhase) { _, _ in reconcilePane() }
  }
}
```

Split detail still auto-shows a register when `pane` is set; otherwise `PhasePlaceholder`. Compact uses `navigationDestination(item: $pane)`. Empty ledger + split + default pane `.all` is what produced `No Transactions`.

### RootTabView wiring

Production always injects `usesSplit: usesSidebar`. Compact and sidebar trees are mutually exclusive.

### IPadLayoutTests new coverage

- `testPhoneRegularAccountsDoesNotPresentEmptyTransactionsSheet`: `RootTabView(usesSidebar: false)` at 844×390, regular size class, fail if OCR/AX contains "No Transactions".
- `testPhoneRegularWidthDoesNotAutoSelectRegisterPane`: `RootChrome.usesSidebar(idiom: .phone, .regular)` is false; `reconciled(current: nil, usesSplit: that)` stays nil.
- Compact snapshot still constructs `AccountsView()` with no `usesSplit` override.

---

## Subagent raw reports

*(paste below when they return)*

### thermo-nuclear-review-subagent

*(pending)*

### thermo-nuclear-code-quality-review-subagent

*(pending)*
