# iOS Edit Rewards

Rewards settings belong to an existing account. **Edit Account** remains separate. The rewards editor owns one draft: child rule screens do not write to the API, and only its main **Save** applies changes. It contains no transaction ledger or transaction flag writes.

## Local preparation

- Follow `apps/ios/AGENTS.md`; build with `scripts/ios-xcodebuild.sh` and install the successful product on its pinned Simulator.
- Launch the disposable stack with `control-howmuch launch`, then `doctor`. Use a distinct `HOWMUCH_VERIFY_STATE_ROOT` when another verification stack is active.
- Set up the synthetic owner and sign in through native Connection using the isolated localhost server, `verifier` / `howmuch-verify-15`. Never use production.
- Use the demo Travel Card account (`acct-credit`). API writes may prepare advanced synthetic fixtures, but creation/edit/save checks below must use the native editor.
- Store evidence under `.amp/in/artifacts/ios-edit-rewards/`: revision and diff, fixture, interaction steps, screenshots, accessibility output and persisted API values. Never put credentials in shared artifacts.

## Entry points

- Empty Rewards: **Set Up Rewards**. Existing board: Rewards menu → **Set Up Rewards**.
- Tap a rewards row to open details, then **Edit Rewards**. The row context menu also offers **Edit Rewards**.
- Stored cards in Rewards import/export can still open their editor, including cards hidden on this device.
- Setup selects one existing available on-budget account. Editing shows a fixed linked-account header, no account chooser. Do not confuse the rewards label with the account name.

## Native checks

1. **Set up.** Select Travel Card, Cashback, rate `1.5`. Calendar cycle has no day picker. Minimum qualifying spend shows `None`; reward-earning spend cap shows `No cap`, with currency units. Save, then GET `/api/import/rewards-tracker?plan_id=local-plan` and confirm the new card links to `acct-credit`. Reopen it from the board.
2. **Cycle and persistence.** Select Billing, then **Cycle starts on → Day 15**. The picker contains integers 1–31, not `15.0`. Preview explains that the day starts the cycle. Save, reopen, verify both the picker and stored `billingCycle`. For as-of 2026-09-26 expect 2026-09-15–2026-10-14. Calendar with a retained day 15 instead gives 2026-09-01–2026-09-30. Inspect the report and board deadline after saving; calendar ignores the stored day.
3. **Clamping.** Exercise days 29, 30 and 31. For 2026-09-26, day 31 gives 2026-08-31–2026-09-29. The focused `RewardDraftPeriodTests` cover both sides of February's boundary (live-date native UI cannot change today's date): on 2026-02-27, day 31 means Jan31–Feb27; on Feb28, Feb28–Mar30. Run these alongside existing `RewardCardEditorTests`.
4. **Advanced draft.** Configured rules appear as summary navigation rows. Unconfigured rules are under **Add a rule…**. Exercise flag-based rewards (including colour names, category import, active/excluded rules, signed priorities and block sizes), spending tiers and per-flag overrides, multi-month qualification, promotion and spend rounding. Fields retain labels and units. Navigate back and reopen a child before Save; it must retain the draft. Save and compare all advanced values in the snapshot. Disabled rules must not disappear. Remove an individual tier and flag while its detail is open: return safely to the collection. For a flag referenced by a tier, removal must also remove that dependent override, preserving unrelated flags and tiers. Verify the saved snapshot has no reference to the deleted flag.
5. **Precedence.** With billing15 and promotion Sep10–Oct10, a 3-month rule anchored Sep1 gives Sep1–Nov30 on Sep26. A future Oct1 anchor leaves the promotion in force. Removing that promotion leaves billing Sep15–Oct14. A promotion with no start uses the underlying current cycle start; an expired promotion falls back to that cycle. The preview is prospective dates, not recalculated earnings. With a pending monthly minimum, the board may count down to Sep30 even when the full period ends Nov30; verify the report's monthly qualification and full-period dates.
6. **Saved metadata.** In **Display & saved details**, inspect rewards label, issuer and Featured. An imported issuer `Unknown` remains stored unless explicitly edited. An unrelated rate/cycle edit must preserve all advanced settings, absent optional configuration and legacy labels. Account name must not change.
7. **Discard.** Change a main field and a child rule, then Cancel. Confirm discard offers a destructive action and retaining the draft. Retain, inspect the edits, then discard. Reopen and GET snapshot: saved values unchanged. Swipe-dismiss must not silently lose dirty edits.
8. **Validation.** Enter a negative/non-number rate; Save stays in the editor with a visible error. Dates remain previewable. Create an incomplete qualification or promotion, return and Save: navigate to the responsible rule with its inline error and retain all input. For a bad rate in the second flag/tier, route to that individual item, not just the collection. Correct it and save successfully. Scroll away from an error and trigger the same error again: it must become visible again.
9. **Network failure.** With a loaded draft, temporarily stop only this disposable API. Save: disable edits during the request, then display an error explaining the draft is retained and Save retries. Restore this same API/database, retry Save, reopen and inspect persisted data. Do not use Cancel as if it undoes a write.
10. **Remove.** **Remove Rewards…** asks for confirmation that the account and transactions remain. Cancel first. Confirm removal on a disposable card, then inspect rewards snapshot, account and transaction counts. It removes rewards settings only.

## Proof and timing

Capture and inspect native screenshots of the ordinary form, advanced summaries, a rule editor and an error/discard state. A web screenshot is not native proof; an editor screenshot is not persistence proof.

If measuring save-to-board latency, use `apps/ios/scripts/rewards-save-to-tile-clock.sh` and three samples, not the approximately 1.6-second `axe describe-ui` call as a clock. The historical recipe budget is 800 ms median; report separately from functional correctness. Use a recording when timing is under review.

When native tools are unavailable, report the native checks as blocked, not passed via API or unit tests.
