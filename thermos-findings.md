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
- [x] Launch thermo-nuclear-review-subagent (`bc-d995e3fd-96b2-52cf-84bc-0a58086ed49b`)
- [x] Launch thermo-nuclear-code-quality-review-subagent (`bc-bd5a061c-a9a4-5d07-a669-c0933a81dabf`)
- [x] Code-quality report landed (2026-09-13 00:46)
- [x] Correctness report landed (2026-09-13 00:47)
- [x] Synthesize unified verdict

### 2026-09-13 00:47 — both passes in; synthesis written

Correctness: no medium/high. Quality: request changes on dual API + dead observer. Unified: merge-ok for the bug; follow-up the structural leftovers if they touch the file again.

## Unified verdict

**No correctness blockers on [#203](https://github.com/yjsoon/howmuch/pull/203) tip `860f213`.** The split gate matches root chrome. Phone regular width no longer auto-presents `No Transactions`. The rotation follow-up is necessary and correct.

**Quality still wants a follow-up before treating the shape as done.** Three reviewers (parent, correctness, quality) all saw the same structural leftover: optional `usesSplit` plus a dead `onChange(of: isSplit)` / `afterSplitChange` layer. That is not a behaviour bug. Quality would request changes anyway; correctness would not block.

**Resolve the disagreement toward correctness for merge, quality for the follow-up.** The PR’s job is the first-launch empty-register bug. Author LGTM’d `860f213`. Do not reopen the rotation/snapshot issues from `0534109`. If they iterate, make `usesSplit` a required `Bool` and delete the observer/helper. That shrinks `AccountsView.swift` instead of growing it 1242 → 1253.

## Findings (deduped)

Weighted by overlap. All three of parent + [Thermo nuclear review](bc-d995e3fd-96b2-52cf-84bc-0a58086ed49b) + [Thermo code quality review](bc-bd5a061c-a9a4-5d07-a669-c0933a81dabf) agree on 1–2. Quality treats them as merge-blocking; correctness and parent do not.

### 1. Dual contract: optional `usesSplit` + `UIDevice` fallback — quality high, correctness low

`AccountsView.swift:80-92`. Production always injects (`Components.swift:473`, `:546`). The nil path exists so `AccountsView()` still compiles (`IPadLayoutTests.swift:94`). Three ways to answer `pad && regular`.

**Fix if iterating:** `usesSplit: Bool` required. No default. No `UIDevice`. Compact test passes `false`. Drop `@Environment(\.horizontalSizeClass)` from this view.

Correctness note: forgetting the argument on phone is still safe because the fallback includes idiom. The old bug was size class alone. So this is not a regression hole for the stated bug; it is a second API.

### 2. `onChange(of: isSplit)` / `afterSplitChange` do not fire in production — quality high, correctness low/nit

`AccountsView.swift:55-73`, `127-134`. `RootTabView` is `if usesSidebar { … } else { … }` (`Components.swift:468-528`). Different TabViews; SwiftUI will not keep `AccountsView` identity. `isSplit` is constant per instance.

Outcomes still match via recreation:
- Leave split → new compact view, `pane == nil`, no auto-push
- Enter split → `onAppear` + `reconcilePane(usesSplit: true)` pins default
- Plus/Max rotation stays stacked because `usesSplit` stays false (the `0534109` bug was watching size class)

Quality: delete `afterSplitChange`, the observer, `isSplit`. Keep `reconciled(usesSplit:)`. `testLeavingSplitClearsPaneSoCompactDoesNotAutoPush` then has no production caller.

Correctness: belt-and-suspenders for the nil fallback / a future host that does not rebuild. Comment slightly oversells it as the slide-over mechanism.

**Judgment:** the quality judo is right if they touch the file again. Not a reason to reject the bugfix.

### 3. File size 1242 → 1253 (pre-existing over 1k)

Quality only, and they say do not extract a module — delete the extra policy instead. Parent agrees. Not a correctness issue.

### 4. `CaptureSnapshotTests` compile churn

Labeled-arg reorder is a no-op. `async throws` is the real Mac compile fix for `try XCTUnwrap` (latent on main). Quality wants it in a separate commit; correctness says not blocking. Do not treat as a layout defect.

### Already closed on this tip (do not re-report)

Author review on `0534109`: rotation pop; snapshot injecting `usesSplit: false` instead of the production tree. Both fixed in `860f213`. Author LGTM. BugBot disabled. No other modules consume this pane machine. No secrets, feature-flags, or devex breaks.

### Intended behaviour

Phone (any size class) = stacked overview, no auto register. iPad regular = split + default pane (empty register chrome is intended). Connection settings sheet unchanged. Web untouched.

## Parent draft (logged in case credits die before subagents return)

Independent of the background reviewers. Confirm or kill against their reports.

### Already handled on tip `860f213` (do not re-report as open)

Author review on `0534109` found two real bugs; follow-up commit claims both fixed; author LGTM on tip.

1. **Rotation pop (was high).** `onChange(of: horizontalSizeClass)` + `afterSizeClassChange` nils `pane` whenever the new width is not regular. iPhone Plus/Max landscape is regular width but `isSplit` stays false, so rotation popped a user-pushed register. Tip watches `onChange(of: isSplit)` instead. Phone rotation does not flip `isSplit`, so `afterSplitChange` does not run. **Fixed.**
2. **Snapshot did not lock production wiring (was medium).** Early snapshot injected `usesSplit: false` on `AccountsView()`, so a revert of `isSplit` to `horizontalSizeClass == .regular` would still pass. Tip hosts `RootTabView(usesSidebar: false)` at 844×390 regular. Everyday + empty loaded ledger is on the harness, so a missing `usesSplit:` pass from `RootTabView` would show `No Transactions` again. **Fixed.**

No BugBot findings (disabled). CI check_runs empty on this query.

### Still open — correctness (parent)

None at medium/high if the tip wiring is taken as written.

Low / residual:

- `testCompactAccountsStillPushesSingleColumn` still constructs `AccountsView()` with no override (`IPadLayoutTests.swift` ~94). Fallback is `RootChrome.usesSidebar(idiom: UIDevice.current, sizeClass: .compact)` which is false on phone *and* on iPad compact. Not a product bug. It does not cover the production compact `RootTabView` path the new test now covers for regular-phone.
- `afterSplitChange` is live only if the **same** `AccountsView` identity sees `isSplit` flip. Production `RootTabView` is `if usesSidebar { … } else { … }`, so slide-over **destroys** the view and `@State pane` resets. Outcomes still match (compact starts nil; split `onAppear` + `reconcilePane` pins default). Not a behaviour bug. The helper still matters for the `usesSplit == nil` fallback on iPad.

### Still open — quality (parent)

- `usesSplit: Bool? = nil` is a second API next to `RootChrome.usesSidebar`. Code judo: make `usesSplit` required (no default). Compact test would have to pass `false`; you cannot silently fall back to `UIDevice`.
- `AccountsView.swift` was already 1242 lines, now 1253. The diff did not create the 1k problem; it also did not extract the pane machine.
- `CaptureSnapshotTests.swift` (3300 lines) drive-by compile fixes are justified (`forbidden` arg order + `throws` for `XCTUnwrap`) but are unrelated to the layout bug.

### Intended behaviour to keep

Phone (any size class) = stacked overview, no auto register. iPad regular = split + default pane. Connection settings sheet unchanged. Web untouched.

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

Returned 2026-09-13 00:47. Agent: [Thermo nuclear review](bc-d995e3fd-96b2-52cf-84bc-0a58086ed49b)

**No medium or high findings.** Tip `860f213` is correct for the stated bug. Would not block on nits. PR discussion not checked (skill: only after medium+).

Gate matches root chrome. Phone regular width no longer installs `NavigationSplitView` or auto-pins a register. iPad regular split still does.

Production trees still land on the right pane even though `onChange(of: isSplit)` does not fire there: `RootTabView` if/else tears identity down. `afterSplitChange` is live only on the nil-fallback / a host that does not rebuild.

`0534109` still watched `horizontalSizeClass` and cleared a pushed register on Plus/Max rotate. `860f213` is that fix.

Tests: phone-regular snapshot hosts production `RootTabView(usesSidebar: false)` at 844×390 regular. Compact `AccountsView()` at `.compact` is safe (fallback false on phone and iPad compact).

Low/nit: belt-and-suspenders observer; compact snapshot omits `usesSplit`; optional duplicates `RootChrome.usesSidebar`. No security, feature-leak, or devex issues. CaptureSnapshotTests labeled-arg reorder is a no-op; `async throws` is the real Mac compile fix.

### thermo-nuclear-code-quality-review-subagent

Returned 2026-09-13 00:46. Agent: [Thermo code quality review](bc-bd5a061c-a9a4-5d07-a669-c0933a81dabf)

**Verdict: request changes.** Bug gate is right. Implementation adds a second chrome API, keeps a change observer that cannot fire in production, and grows an already-1.2k-line view instead of deleting the size-class machinery.

1. **Structural regression: optional `usesSplit` plus `RootChrome` fallback is a second source of truth.** Production `RootTabView` always passes the flag (`Components.swift:473`, `:546`). The nil path exists so `AccountsView()` still compiles (`IPadLayoutTests.swift:94`). Required `usesSplit: Bool`. No default. No `UIDevice`. Drop `@Environment(\.horizontalSizeClass)` from this view.

2. **Code judo: `afterSplitChange` + `onChange(of: isSplit)` should disappear.** With the injected flag, `isSplit` is constant for the life of the view. `RootTabView`'s if/else tears the tree down when `usesSidebar` flips. `onChange` cannot fire in production. Delete `afterSplitChange`, the observer, `isSplit`, and `horizontalSizeClass`. Keep `reconciled(usesSplit:)`. `testLeavingSplitClearsPaneSoCompactDoesNotAutoPush` tests a function the view tree no longer needs.

3. **Spaghetti: a chrome flag with three names, still branched locally.** `RootChrome.usesSidebar` → `RootTabView.usesSidebar` → `AccountsView.usesSplit` → `isSplit`. Same predicate, new vocabulary.

4. **Type / boundary: `Bool? = nil` papers over the invariant.** Real invariant: accounts surface is the sidebar split iff chrome is. Leftover `AccountsView()` compact host is the same hole.

5. **File size: 1242 → 1253, still over 1k.** Delta is extra policy. Delete the second API rather than extract a module.

6. **Tests:** `testPhoneRegularAccountsDoesNotPresentEmptyTransactionsSheet` is the right proof. `CaptureSnapshotTests.swift` argument reorder + `async throws` is compile noise on a 3300-line file; land separately. The `throws` fix is real; the argument swap is not.

**Bar:** behavior can be correct and this still should not land as-is. Make `usesSplit` required, stop re-deriving chrome, delete the observer/`afterSplitChange` layer.
