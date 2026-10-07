# Notification UI E2E — `2d14080bcaaf3f631d6d63a11ef09fd4848c258c`

## Result

Real iPhone 17 / iOS 26.5 Simulator UI verification used device
`EDD9B083-63F1-44E6-9A7B-0A6964CC2561`, the supplied Debug Simulator
product, native Photos sharing, native Home/backgrounding, native Notification
Center actions, and read-only App Group/SQLite snapshots.

The Ready/Review and Already-in-only flows passed. The failed-job notification action remains
**untested** because neither real non-transaction share delivered a
notification. The run did not establish that failure completion occurred
while the app was inactive, so the timing explanation is unconfirmed.

## Shell validation

A fresh `scripts/ios-xcodebuild.sh test` run on the exact revision passed with
Xcode 27.0 RC (`27A266a`) and ad-hoc Simulator signing. The xcresult reported
**793 passed, 0 failed, 2 skipped (795 total)**. `IntakeLineParserTests`
reported **43 passed, 0 failed, 0 skipped** and `IntakeMatcherTests` reported
**26 passed, 0 failed, 0 skipped**. The build-for-testing and
test-without-building phases both exited 0. The two skipped tests were
`CaptureInterpreterTests/testLiveFoundationModelsCoffeeAddUpdateAndTodayQuery()`
and `LocalModeTests/testLocalModeScreensRender()`. No compiler errors were
reported. Xcode timed out collecting Simulator diagnostics after 600 seconds,
but reported test execution succeeded.

## Preconditions and preservation

- Exact checkout: `2d14080bcaaf3f631d6d63a11ef09fd4848c258c`.
- Existing local-only authentication and synthetic ledger retained.
- Historical active jobs were preserved before this run; no historical
  transaction or ledger row was deleted.
- Native Settings → Apps → Halation → Notifications visibly showed Allow
  Notifications enabled, with Lock Screen, Notification Center, Banners,
  Sounds, Badges and Always previews enabled. No setting was changed.
- Clean baseline: 4 live / 6 historical transactions; DBS Altitude
  `-$63.45`; icon badge zero.
- Model assets remained unavailable in Simulator and the documented fallback
  parser ran. This is synthetic local data, not production data.

## A — one NEW line, Ready notification and Review

Fixture: `A3-large-new-3328.png`, 4096×4096:

```text
05 OCT TOAST BOX -33.28
```

The published fixture link is a 1200×1200 preview; the original 4096×4096
fixture remains local-only.

The fixture was shared from Photos to DBS Altitude / Auto. On Home page 2,
Halation was tapped by direct coordinate and Home was immediately pressed in
the same input sequence, avoiding accessibility read-back delay.

| Check | Expected | Observed | Result |
|---|---|---|---|
| Notification title | `Ready to review` | Exact title visible | PASS |
| Notification body | Counts + account/source only | `1 new, from 1 DBS Altitude screenshot` | PASS |
| Privacy | No payee or amount | Neither `TOAST BOX` nor `$33.28` appeared | PASS |
| Badge | 1 | Home icon visibly showed `1` | PASS |
| Actions | Review and Later | Both visible in expanded notification | PASS |
| Review route | Exact generating batch | Opened batch at `8:16 AM` with original image and `NEW TOAST BOX -$33.28` | PASS |
| Stability | No crash | Same process continued; no crash signatures | PASS |

Persisted identity:

```text
job      AAE74FBA-3712-4B80-9493-204526E5849C
proposal 7EB54DEA-D4B2-4F6F-B1AC-A8841C65D006
action   halation.inbox.review
```

The batch was rejected through Review → Reject batch → Discard. The UI said
`Nothing was saved.` Badge returned to zero and the ledger remained unchanged.

System trace:

```text
Adding notification request ... identifier: AAE74FBA-3712-4B80-9493-204526E5849C
Received response ... for action halation.inbox.review
Launch application in foreground for notification response action halation.inbox.review
Foreground application launch succeeed for action response halation.inbox.review
```

SpringBoard also logged `BSActionErrorDomain code:4 ("empty-response")` after
the successful foreground launch, as on prior Simulator runs; observed routing
and app stability nevertheless passed.

## B — Already-in-only suppression

Fixture:

```text
05 OCT KOPITIAM AMK -8.90
SYNTHETIC COPY
```

The image was shared through Photos to DBS Altitude / Auto and Halation was
backgrounded during reading. Starting badge was zero.

| Check | Expected | Observed | Result |
|---|---|---|---|
| Classification | One ALREADY IN row | `KOPITIAM AMK -$8.90`, `Matches 5 Oct in DBS Altitude` | PASS |
| Notification | None | Notification Center remained visually empty for 60 seconds | PASS |
| Badge | 0 | Home icon remained unbadged before and after the full interval | PASS |
| Persistence | No write | Accounts, transactions and deletion flags unchanged | PASS |

Persisted identity:

```text
job        455AAEB9-5B9E-4651-9E49-4125819B8738
proposal   DB2BE370-8F09-48FE-A51D-E7A48A9F416F
matched tx e2e-existing-kopitiam
```

The batch was then rejected through native UI; no ledger write occurred.

## C — natural failure and notification Discard (**UNTESTED**)

The failed-notification `notificationDiscard` path is **UNTESTED**, not a pass
or a suppressed result. A failed notification would have been required before
its title/body, native actions, routing, and Discard persistence could be
assessed.

Two real Photos shares were tried without job/proposal/notification injection:

1. `C-no-text.png`, a blue non-transaction image.
2. `C2-large-no-text.png`, the same blue non-transaction image resized to
   4096×4096 for one focused timing adjustment.

The published C2 fixture link is a 1200×1200 preview; the original 4096×4096
fixture remains local-only.

Both naturally produced:

```text
Couldn't read this. No text was found.
```

The small job was `1C7CED86-2402-4D71-8285-A1B816909B2A`; it was discarded
through the in-app failed-job screen before the focused retry. The final large
job is `A051B61D-1BE7-4F47-BBD0-C2A49D35BF90` and remains `failed` in the
Inbox as evidence.

Neither share posted a failed notification; Notification Center was empty.
The run did not establish inactive-state completion. Therefore title/body, native
Open Inbox/Discard actions, and Discard persistence **could not be tested**.
No payload, job, proposal, delegate call, database write or fabricated
notification was used to bypass that blocker.

## Read-only persistence comparison

Baseline vs final:

```text
accounts                   equal
transactions               equal
deletionFlags              equal
activeTransactions         equal
transactionsWithCategories equal
categories                 equal
```

Both snapshots have four live transactions. DBS Altitude remains `-$63.45`;
Everyday Account and Closed remain `$0.00`. No target amount was written.

## Runtime observations

- No `Call must be made on main thread`.
- No `Terminating app`.
- No `Assertion failure`.
- Simulator background scheduling repeatedly logged:

```text
Couldn't schedule refresh: The operation couldn’t be completed.
(BGTaskSchedulerErrorDomain error 1.)
```

Successful Ready delivery was foreground → immediate native Home completion,
not proven OS-scheduled background execution.

## Evidence map

- New-line fixture preview (source was 4096×4096):
  [A3-large-new-3328-preview.png](A3-large-new-3328-preview.png)
- Already-in fixture: [B-already-kopi.png](B-already-kopi.png)
- Natural-failure fixtures:
  [C-no-text.png](C-no-text.png) and
  [C2-large-no-text-preview.png](C2-large-no-text-preview.png)
- Notification settings: [05-notifications-enabled.png](05-notifications-enabled.png)
- Ready banner and badge: [07-ready-banner-badge.png](07-ready-banner-badge.png)
- Expanded actions: [08-ready-actions.png](08-ready-actions.png)
- Review exact batch: [09-review-opened.png](09-review-opened.png)
- Badge zero after cleanup: [10-zero-badge-after-reject.png](10-zero-badge-after-reject.png)
- Empty Notification Center after 60 seconds:
  [11-already-empty-notification-center-60s.png](11-already-empty-notification-center-60s.png)
- Already-in batch: [12-already-in-batch.png](12-already-in-batch.png)
- Empty notification surface after final failed attempt:
  [14-failed-empty-notification-center.png](14-failed-empty-notification-center.png)
- Final natural failed job:
  [14-failed-inbox-no-notification.png](14-failed-inbox-no-notification.png)
- Clean baseline snapshot: [01-clean-baseline.json](01-clean-baseline.json)
- Clean final snapshot: [06-clean-final-baseline.json](06-clean-final-baseline.json)
- Ready snapshot: [07-ready-notified.json](07-ready-notified.json)
- Review snapshot: [09-review-opened.json](09-review-opened.json)
- After-reject snapshot: [10-after-reject.json](10-after-reject.json)
- Already-in snapshot: [12-already-in.json](12-already-in.json)
- Natural-failure snapshot:
  [13-natural-failed-no-notification.json](13-natural-failed-no-notification.json)
- Final failed snapshot: [14-final-failed-pending.json](14-final-failed-pending.json)
- Machine-readable comparisons: [evidence-checks.json](evidence-checks.json)
- Focused runtime trace: [runtime-excerpt.log](runtime-excerpt.log)

Recordings are local-only and excluded from the publication whitelist:

- `notification-ready-already.mp4`
- `notification-failed-unreachable.mp4`
