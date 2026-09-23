# Rewards redesign (direction A): agreed implementation spec

## Structure
- Board = `List(.plain)`, hidden separators, clear row backgrounds, rounded card drawn inside row content (RegisterView pattern). Detail = push via NavigationLink(value: cardID), looked up live from the parent report. Editor stays a sheet, reached by an explicit Edit toolbar button in detail and "Edit Card" in the row context menu. Never open the form directly from a row.
- Featured and Today menus: two separate native `Menu`s with `.buttonStyle(.glass)` in a `GlassEffectContainer`, pinned with `.safeAreaBar(edge: .top)`. Pinned = floating chrome, so glass is legitimate there; rows themselves never get glass/material. Deployment target is iOS 26, so no availability fallback.
- Summary line under the menus (first list row): report-scope totals (account scope applies; Featured/hidden never change numbers). "≈" only when miles contribute with non-zero valuation. Labelled status counts, zeros omitted ("2 below minimum · 1 failed · 1 capped"). When rows are filtered/hidden, append "· showing 4 of 7". Tapping the summary pushes a Summary screen (headline totals + groups breakdown table + group-by menu). Board always fetches `.flag`; `group` leaves the board fetchKey.
- One "…" menu: extend `DestinationsMenu` with a leading Rewards section: Add Card · Customise Board… · Accounts… · Miles Valuation… (medium-detent Form sheet) · Import & Export…; then divider; existing app-wide items. The global + is untouched.
- Today menu: ✓ Today / Choose Date… (medium sheet, graphical DatePicker, max = today in Singapore, "Today" and "Done") / Range Report… (push; reuses Summary screen with range + group controls; never shown as progress rows). Past date → menu label shows the date, first item "Back to Today", plus an inline banner under the summary with "Back to Today". Today sends `to: nil`; past dates formatted in Asia/Singapore.
- Featured menu: Picker Featured (n) / All Cards (n); toggle "Group by Reward Type" (reuses collapsedGroups via Section(isExpanded:)); default Featured only when ≥1 card is featured.
- Customise Board = existing display-preferences sheet renamed; single list when ungrouped. Fix reorder so moving within a subset keeps other cards' relative positions. Board footer "2 hidden · Show" when any are hidden. Context menu: Edit Card, Hide on This Device. Trailing swipe: Hide (grey, not destructive). Hiding stays persistent.
- Pull to refresh kept; on failure keep stale rows with an inline error row.
- Empty states (ContentUnavailableView, controls stay visible): no cards at all (Add Card / Import Rewards); none in selected accounts (Show All Accounts); all hidden (Show Hidden Cards); Featured shows nothing (Show All Cards).
- `RewardsBoardPreferences` decoding must tolerate missing fields (decodeIfPresent) so existing prefs survive.

## Row projection (pure, tested; `RewardRowProjection.make(row:asOf:isRange:)`)
- Decode extra `RewardsFlagRow` fields (optional): countedSpend, minimumSpend, minimumSpendMet, maximumSpend, maximumSpendExceeded, blockSize.
- Never use minimumSpendProgress / maximumSpendProgress / `period` label. Fill and line 3 always share one basis computed from raw values.
- Dominant action, first match wins: (1) qualification failed → "Monthly minimum missed", resets in N, no fill, failed tone; (2) active monthly qualification month behind → "$X to this month's minimum", month spend/min, deadline = month end, amber; (3) card minimum unmet (totalSpend < minimumSpend, raw compare) → "$X to minimum", amber, X rounded up to cent; (4) next tier (hasNext && threshold > totalSpend) → "$X to next tier", mint, plus "Current tier cap reached" exception if exceeded; (5) cap headroom → "$X left before cap", countedSpend/maximumSpend, mint; (6) terminal cap (exceeded && (shouldStopUsing == true || hasNext != true)) → "Cap reached", "Resets in N days", fill 1, complete tone, "$Y beyond cap" if over; (7) no target → "No cap", fill nil. Range mode → no fill, no days; line 2 earned, line 3 spend.
- Exceptions on collapsed row (up to 2, then "+N more"): category at/over cap (flag cap exceeded while card cap not), category minimum unmet, qualification pending (when not dominant), intermediate cap.
- Days: from report.asOf and the `periods` entry containing it, compared as civil dates in a Gregorian Asia/Singapore calendar; injected clock only as fallback; never Date() in the projection. days = end − asOf + 1 (inclusive). 1 → "Last day"; otherwise "N days left" / "Resets in N days".
- Ordering: saved order, then days left for unsaved cards.

## Visual
- Fill: custom `LeadingFill` Shape (animatableData = fraction, square edge, respects layoutDirection) in the row's `.background`, clipped to continuous 18pt rounded rect; animate only on value change, none under Reduce Motion. Increase Contrast: stronger fill, 1pt stroke, ink tick at fill edge (Theme needs a contrast-aware colour initialiser).
- Tones (track / fill / ink), light | dark: amber #FFF7EC/#FBE2C2/#9A5410 | #262117/#46351A/#F1B566; mint #F0F9F3/#CBEBD7/#1A6E44 | #17261F/#1F4631/#6BC78C; terminal lavender #F5F4FB/#E2E0F5/#5A578F | #1F1E33/#322F58/#B9B6F0; no-target & failed: Theme.card, no fill (failed uses Theme.outflow warning line).
- Text never changes colour across the fill; use new `Theme.rowSecondary` (#4E5468 / #B3B8C9), never `.secondary`, on tinted rows.
- Type: name .headline (2 lines) + custom chevron; amount .title2.bold monospaced + .body label; deadline trailing .subheadline, first-text-baseline, tone ink + semibold at ≤3 days; line 3 .subheadline rowSecondary; exceptions .footnote.medium Label with triangle. @ScaledMetric padding 14/16 (~104pt). Accessibility sizes: deadline wraps below action.
- VoiceOver: one element, label = card name, value = action, basis with percent, deadline, earned, exceptions; custom actions Edit, Hide.

## Detail screen
Status (action + period + days, past-date banner) · Targets (min on raw spend, cap on counted spend, each labelled ProgressView) · Tiers (active + next) · Qualification months · Categories (rate, earned, labelled cap rows) · Periods (if >1) · Transactions › (extract editor's ledger into `RewardCardLedgerView`, reused by editor).

## Out of scope
No server/calculator changes, no "hide until next cycle", no web changes. Existing snapshot tests retargeted.

## Sign-off amendments (all three designers agreed subject to these)
- Step 3 minimum: amount/fill from raw `max(0, minimumSpend − totalSpend)`; branch taken when gap > 0. If gap is 0 but `calc.minimumSpendMet == false` and qualification is not pending/failed (e.g. tier minimum), show exception "Minimum not yet met"; the row never implies rewards are unlocked when the server says they are not. Pending monthly qualification keeps the "Rewards unlock after …" exception.
- Step 5 cap headroom applies only when the cap is not exceeded.
- Deadline wording: action deadlines "N days left" / "Last day"; resets "Resets in N days" / "Resets tomorrow"; ≤0 or no matching period "Period ended".
- Range mode suppresses collapsed-row exceptions (server merges flags across periods).
- Status counts derive from row tone; "capped" = terminal cap only.
- Detail Targets for monthly-qualification cards shows active month spend vs monthly minimum too.
- Ordering fallback: days left, then name.
- Summary screen reuses the board fetch (same as-of + account scope, only `group` differs) and states that scope in its header.
- Date picker: calendar/timezone pinned to Asia/Singapore, ISO built with the same calendar; test with non-Singapore device TZ.
- Active account scope gets a third pinned glass button ("2 Accounts ✕": tap opens picker, ✕ clears). Account picker lists accounts that have reward cards, including closed ones.
- Pinned menu bar uses ViewThatFits to stack at accessibility sizes on small iPhones.
- Miles valuation sheet keeps explanatory footnote, validation and save error. Customise Board keeps Show All Cards and Reset display preferences.
- Range Report keeps month/preset/custom ranges via `ReportFilterBar`.
- Editor keeps its embedded ledger for now (via extracted `RewardCardLedgerView`); iPad uses single column at readable width.

## Native review amendments (2026-09-23)
Made after the first simulator renders; these supersede the matching lines above.
- Featured and Today sit in one rounded card-coloured bar as the first list row, not a pinned glass `safeAreaBar`. The pinned bar dimmed the large "Rewards" title, and the concept draws a single bar under the title. Each menu label shows a chevron. At accessibility sizes the bar stacks.
- Monthly qualification reads "$X to monthly minimum". The action never wraps mid-phrase: if it and the deadline don't fit on one line, the deadline drops below.
- Fallback order puts cards that still need spend (minimum, monthly minimum, next tier, cap headroom) first by nearest deadline, then capped, failed and untargeted cards by reset, then name.
- Increase Contrast uses the stronger fill and the 1pt outline only; the fill-edge tick crossed glyphs.
- Detail sheet: status row in its own clear section without the repeated card name, opaque grouped background, "View Transactions", and progress tints that follow the row tones.
- The summary line is omitted when there are no cards; the "N hidden · Show" footer is omitted when the all-hidden empty state already offers Show Hidden Cards.
