# Thermos review of [PR #203](https://github.com/yjsoon/howmuch/pull/203)

Logged on [PR #204](https://github.com/yjsoon/howmuch/pull/204). Tip at review time: `860f213` on `cursor/first-launch-empty-sheet-8bbc`. This document does not re-review later commits.

**Status:** #203 merged as `d926a41`. Quality leftover (required `usesSplit`, drop dead observer) is [PR #205](https://github.com/yjsoon/howmuch/pull/205).

## Verdict

No correctness blockers on `860f213`. The split gate matches root chrome; phone regular width no longer auto-presents `No Transactions`; the rotation follow-up is necessary and correct. Quality still wants a follow-up: optional `usesSplit` plus a dead `onChange(of: isSplit)` / `afterSplitChange` layer. That is not a behaviour bug. Merge the bugfix; if the file is touched again, make `usesSplit` a required `Bool` and delete the observer/helper so `AccountsView.swift` shrinks instead of growing 1242 → 1253.

## Findings

### 1. Dual contract: optional `usesSplit` + `UIDevice` fallback

`AccountsView.swift:80-92` — `usesSplit: Bool? = nil`, then `UIDevice` + size-class fallback. Production always injects from `RootTabView` (`Components.swift:473`, `:546`). The nil path exists so `AccountsView()` still compiles (`IPadLayoutTests.swift:94`). Three ways to answer `pad && regular`.

If iterating: required `usesSplit: Bool`, no default, no `UIDevice`. Compact test passes `false`. Forgetting the argument on phone is still safe because the fallback includes idiom; not a regression hole for the stated bug, but a second API.

### 2. `onChange(of: isSplit)` / `afterSplitChange` do not fire in production

`AccountsView.swift:55-73`, `127-134`. `RootTabView` is `if usesSidebar { … } else { … }` (`Components.swift:468-528`); SwiftUI will not keep `AccountsView` identity, so `isSplit` is constant per instance. Outcomes still match via recreation (leave split → compact with `pane == nil`; enter split → `onAppear` + `reconcilePane` pins default). Quality wanted the observer/helper deleted; correctness called this a nit, not a behaviour bug.

### 3. File already over 1k

`AccountsView.swift` 1242 → 1253. Do not extract a module — delete extra policy instead.

### 4. `CaptureSnapshotTests` compile churn

Labeled-arg reorder is a no-op. `async throws` is the real Mac compile fix for `try XCTUnwrap`.

## Already closed on this tip

Rotation pop and snapshot-not-locking-production-tree were fixed in `860f213`. Author LGTM. BugBot disabled.

## Intended behaviour

Phone (any size class) = stacked overview, no auto register. iPad regular = split + default pane. Connection settings sheet unchanged. Web untouched.
