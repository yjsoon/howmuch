# Verification checklist — YNAB-style usability changes

These changes were written in an environment without Xcode, a simulator or
`swiftc`, so nothing here has been compiled or run. Please verify locally.

## 1. Build

From the repo root:

```sh
xcodebuild -project apps/ios/HowMuch.xcodeproj -scheme HowMuch -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/howmuch-derived CODE_SIGNING_ALLOWED=NO CLANG_MODULE_CACHE_PATH=/tmp/howmuch-module-cache SWIFT_MODULECACHE_PATH=/tmp/howmuch-module-cache build
```

If the build fails at project load, suspect the `project.pbxproj` edit first
(see "Risky changes" below).

## 2. Manual test script

Run against a server with imported YNAB data (so the "Hidden Categories",
"Non-Personal (Don't Summarise)", "Inflow" and "Uncategorised" groups exist).

### Reports — ranges and stepper

1. Open Reports. The range row should default to **This month** with a
   `‹ June 2026 ›` stepper above it (current month, serif label).
2. Tap `‹` twice. The stepper should read two months back, no preset segment
   should be highlighted, and all cards except Age of Money should refetch
   for that calendar month.
3. Tap `›` once. The stepper should land on last month and the **Last month**
   segment should re-highlight (stepping normalises back onto the presets).
4. Select **3M**, **YTD**, **1Y** in turn: the stepper should disappear (the
   range is no longer a single calendar month) and cards should refetch.
5. Verify the network traffic (server logs or proxy): every
   `/api/reports/*` request carries `plan_id`, and
   `/api/reports/age-of-money` is requested **without** `from`/`to` whatever
   range is selected. The Age of Money card should carry the caption
   "Measured across full history…".
6. Change the interval picker; income/net-worth/age-of-money refetch.

### Reports — quiet-group exclusion

7. On the spending card, with data in hidden/non-personal groups in range:
   the total and rows should exclude them and a caption should read
   "_amount_ in hidden & non-personal categories excluded." with an
   **Include** button.
8. Tap **Include**: total and rows now include the quiet groups, caption
   flips to "Including hidden & non-personal categories." with **Exclude**.
   Share bars should re-proportion against the new visible total.

### Remembered view options

9. Select **Last month**, interval **Week**, and **Include** quiet spending.
   Kill the app and relaunch: Reports should restore all three.
10. Step to an arbitrary month, kill and relaunch: the same month should be
    restored (the stepped month is remembered verbatim).

### Capture — category picker and persistence

11. Open Capture → Category. The picker should push a list (not a menu):
    everyday groups first, then the bookkeeping groups (Hidden Categories,
    Non-Personal, Inflow, …) at the bottom in secondary (grey) text.
    "Uncategorised" stays at the very top.
12. Save a transaction with a chosen account and category. Kill the app,
    relaunch, open Capture: the same account and category should be
    pre-selected.

### Recents — uncategorised pill

13. With at least one loaded transaction that has no category, no transfer
    and no splits, Recents should show a red-tinted "N uncategorised" pill
    above the list. Transfers and splits must not count.
14. Tap it: the list filters to just those transactions and the pill reads
    "Showing uncategorised · Clear". Tap again to clear.
15. With zero uncategorised transactions the pill should not appear at all.

## 3. Risky / statically unverified changes

- **`project.pbxproj`** — hand-added entries for
  `Models/ReportRange.swift` (file reference `A1000000000000000000001A`,
  build file `A1000000000000000000002A`, Models group child, Sources phase
  entry), copied from the existing pattern. A typo here breaks project
  loading; verify Xcode opens the project and the file appears under
  *Models*.
- **`ReportRange` Codable synthesis** — an enum with an associated value
  (`.month(YearMonth)`) relies on compiler-synthesised Codable. If the
  toolchain rejects it, write the Codable conformance by hand.
- **Custom segmented range row** — built from buttons (not a `Picker`)
  because a stepped `.month(...)` selection matches no preset tag. Check the
  five labels fit on an iPhone SE-class width (they use
  `minimumScaleFactor(0.7)`).
- **`.pickerStyle(.navigationLink)`** on the capture category picker changes
  the interaction from a menu to a pushed list; confirm `foregroundStyle(.secondary)`
  actually renders the quiet rows dimmed there, and that selection pops back
  correctly inside the sheet's `NavigationStack`.
- **Local vs UTC dates** — the new range presets resolve using the local
  calendar (matching the web), but capture still stamps transaction dates
  with the pre-existing UTC formatter (`Date.isoDateString`). Near midnight
  these can disagree by a day; unchanged behaviour, just now more visible.
- **`ViewPrefs` decoding** — adding fields later invalidates stored blobs
  wholesale (decode failure falls back to defaults), same trade-off as the
  existing `APISettings`.
- **Stale remembered category** — `seedIfNeeded` now validates the persisted
  category id against live categories; worth one test after deleting the
  remembered category server-side.
