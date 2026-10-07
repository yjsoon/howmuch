# Rewards Exposure card

Implementation spec. It replaces the iOS Rewards progress fill (`RewardFilledRow`) with the Exposure card the web board already draws. It also moves the web face onto the iOS row's rules, so a card reads the same on both platforms. This slice has no code. The Swift and TypeScript below are sketches, unverified because this machine has no Xcode.

Read it with [the agreed filled-rows spec](../plans/rewards-filled-rows-agreed-spec.md). That spec still owns what a row says: precedence, wording, rounding, deadlines, ordering and the summary line. This document owns how the card looks and moves. Paths are relative to the repository root. iOS paths without a prefix are under `apps/ios/HowMuch/`.

## Goal and non-goals

**Goal.** Each card becomes a small photograph: a sky, the two-layer brand ridge and a sun.

- The sun's **height** is the projection's `fill`, which is progress toward the card's current target. Nothing else moves it.
- The sun's **position across the sky** is time: how much of the deadline's window is already behind the as-of day.
- The **halation rings** step in by quarters: one ring at 25%, four rings only when the target is reached.
- At a terminal cap the sun **sets** behind the ridge and the sky dims. The card is done, not failed. A failed qualification prints in **monochrome** with no sun. A card with no target has **no sun**.
- Every word and figure the current row shows stays, unchanged, from `RewardRowText`. The picture replaces the coloured fill and nothing else.

**Non-goals.**

- No server or calculator change. The time window comes from fields the report already sends (`periods`, `monthly_qualifications`).
- No change to precedence, wording, rounding, deadlines, ordering, the summary line or the VoiceOver strings.
- No Apple Wallet look: no chip, no masked number, no network mark, no ID-1 ratio, no stacked pile of cards, no flip.
- No count-up or rolling digits, and no idle animation.
- No widget or Live Activity in this slice. The paper row below is the likely widget layout later.
- No iOS restyle to Dusk Ridge chrome (plum and warm paper). Faces are brand prints and look the same in every look and mode, on both platforms. The chrome around them stays iOS's own.
- No daily spend series (the "Spend Ridge" concept) and no per-month film strip (the "Contact Strip" concept). Both are later candidates for the detail sheet.
- The detail sheet keeps its sections (Targets, Tiers, Qualification months, Categories, Periods). Only its header changes.

## What the card communicates

### Channels

| Channel | Source | Rule |
| --- | --- | --- |
| Sun height | `projection.fill`, 0 to 1 | Linear from resting on the ridge (0) to the zenith (1). Never computed from anything else, so the picture cannot show a number the basis line does not. |
| Sun position across | new `projection.elapsed`, 0 to 1 | Linear across the layout's lane. With no as-of date the sun sits at 0.6 of the lane. |
| Rings | `fill` | `floor(4 × fill)` rings, so 0 to 4. Four rings means the target is reached. |
| Exposure | `tone` | `needsMinimum`, or `neutral` with a fill: underexposed. `earning`: full. |
| Sun state | `action` | Terminal `capReached`: set. `qualificationFailed`, `noTarget` or no fill: no sun. |
| Sky | `rewardType` | Miles: night sky. Cashback: day sky. The earned unit says the same in words. |
| Pace line, sheet only | `fill` against `elapsed` | Only for `minimum`, `monthlyMinimum` and `nextTier`. A cap is a ceiling, not a goal, so cap states never get one. Never spoken. |

The **window** behind `elapsed` is the date range the deadline closes: the active month for `monthlyMinimum`, otherwise the card period that contains the as-of day. `elapsed = (asOf − start) / (end − start + 1)` in Singapore civil days, clamped to 0…1. The as-of day is still spendable, so it counts as remaining, which matches the inclusive "8 days left". Elapsed and remaining always add up to one whole window.

### State table: the picture

Examples are the `RewardRowProjectionTests` fixtures in `apps/ios/HowMuchTests/RewardsReportTests.swift`. They use SGD, as of 23 Sep 2026, with a 1 to 30 Sep period unless noted. So `elapsed` is 22/30 = 0.733, and on the board strip the sun sits at 0.86 of the row width.

| # | State | Trigger in the projection | Sun height and position | Rings and exposure | Sky, ridge and colours |
| --- | --- | --- | --- | --- | --- |
| 1 | Below minimum | `.minimum`, tone `needsMinimum` | Rising, 0.8725 of its travel; across 0.733 | 3 rings; underexposed: core `SunCoreUnder` #E2A95C, halo × 0.7 | Sky by type, normal ridge. Sheet pace line on. |
| 2 | Monthly minimum behind | `.monthlyMinimum`, `needsMinimum`; the window is the month | 0.833 (250 of 300); across 0.733, from September inside an August to October period | 3; underexposed | As 1 |
| 3 | Next tier | `.nextTier`, `earning` | 0.8375; 0.733 | 3; full | Normal. Sheet pace line on. |
| 4 | Intermediate cap | `.nextTier` with exception `tierCapReached` | As 3. The sun does **not** set. Web R1 sets it today; that is a bug. | 3; full | As 3; exception in the slip |
| 5 | Cap headroom | `.capHeadroom`, `earning` | 0.65 (650 of 1,000 counted); 0.733 | 2; full | No pace line |
| 6 | Minimum met | `.minimumMet`, `earning` | 1, at the zenith | 4; full | Crest stroke at 90% |
| 7 | Top tier | `.topTier`, `earning`, no basis | 1 | 4; full | As 6 |
| 8 | Cap reached, not terminal | `.capReached(terminal: false)`, `earning` | 1 | 4; full | As 6. Rare: a next tier exists at or below spend. |
| 9 | Terminal cap | `.capReached(terminal: true)`, `complete` | Set: centre 0.6 r below the front crest, at its across position | None; afterglow along the crest, 0.25 of the width either side of the sun | `Dim` overlay over the sky, clear to 18% #1C1B18. Headline in foot ink. |
| 10 | Partial-block cap | As 9, basis 995 of 1,000 | Set. The picture follows the action, the figure stays raw (below). | None | As 9 |
| 11 | Failed | `.qualificationFailed`, `failed` | No sun | None | Monochrome (saturation 0.15), no horizon warmth. Headline in `FailedInk` #FFABAE. |
| 12 | No target | `.noTarget`, `neutral`, no fill | No sun | None | Horizon warmth only |
| 13 | Rewards withheld | `.noTarget` with `rewardsLocked` or `minimumNotMet` | No sun | None | As 12; exception in the slip |
| 14 | Neutral with a target | A target action whose `earning` tone the projection downgraded to `neutral` because the card is not qualified | Rising at fill | Rings by quarter; underexposed | As 1. Pace line only if the action allows it. |
| 15 | Range | `.range` | No picture at all | | Paper row without a print |
| 16 | No as-of date | Any; `deadline` and `elapsed` are nil | Rising at fill, fixed at 0.6 of the lane | By its tone | No pace line, no day ticks |

An urgent deadline is not a picture state. Any `.ends` deadline within 3 days sets the deadline text in SemiBold `UrgentInk` (#FFD98C) on the ridge, or the tone ink on paper, exactly as today.

### State table: words and VoiceOver

The label is always the card name (`projection.title`), or "Rewards, <name>" in the register, with the hints unchanged. The value is `RewardRowText.accessibilityValue`, unchanged.

| # | Example (test line) | Card text: headline · deadline, then the basis line | VoiceOver value |
| --- | --- | --- | --- |
| 1 | `:1026` minimum 800, spend 698 | **$102.00** to minimum · 8 days left; $698.00 / $800.00 · $0.00 earned | $102.00 to minimum. $698.00 of $800.00, 87 per cent. 8 days left, ends 30 Sep. $0.00 earned |
| 2 | `:1231` September pending, 250 of 300 | **$50.00** to monthly minimum · 8 days left; $250.00 / $300.00 · $0.00 earned | $50.00 to monthly minimum. $250.00 of $300.00, 83 per cent. 8 days left, ends 30 Sep. $0.00 earned |
| 3 | `:1076` 1,340 toward 1,600, earned 76 | **$260.00** to next tier · 8 days left; $1,340.00 / $1,600.00 · $76.00 earned | $260.00 to next tier. $1,340.00 of $1,600.00, 84 per cent. 8 days left, ends 30 Sep. $76.00 earned |
| 4 | `:1087` tier cap 1,000 exceeded, next tier 1,600 | **$260.00** to next tier · 8 days left; $1,340.00 / $1,600.00 · $0.00 earned; slip "Current tier cap reached" | $260.00 to next tier. $1,340.00 of $1,600.00, 84 per cent. 8 days left, ends 30 Sep. $0.00 earned. Current tier cap reached |
| 5 | `:1050` cap 1,000, spend 700, counted 650 | **$350.00** left before bonus cap · 8 days left; $650.00 / $1,000.00 · $0.00 earned | $350.00 left before bonus cap. $650.00 of $1,000.00, 65 per cent. 8 days left, ends 30 Sep. $0.00 earned |
| 6 | `:1042` minimum 800, spend 800 | Minimum met · Resets in 8 days; $800.00 / $800.00 · $0.00 earned | Minimum met. $800.00 of $800.00, 100 per cent. Resets in 8 days, period ends 30 Sep. $0.00 earned |
| 7 | `:1113` spend 1,650, earned 90 | Highest tier active · Resets in 8 days; $1,650.00 spent · $90.00 earned | Highest tier active. $1,650.00 spent · $90.00 earned. Resets in 8 days, period ends 30 Sep. $90.00 earned |
| 8 | No dedicated test | Bonus cap reached · Resets in N days | As the text |
| 9 | `:1097` cap 2,000, spend 2,150, earned 80 | Bonus cap reached · Resets in 8 days; $2,000.00 / $2,000.00 · $80.00 earned · $150.00 beyond cap | Bonus cap reached. $2,000.00 of $2,000.00, 100 per cent. Resets in 8 days, period ends 30 Sep. $80.00 earned |
| 10 | `:1153` spend 996, counted 995, cap 1,000 | Bonus cap reached · Resets in 8 days; $995.00 / $1,000.00 · $0.00 earned | The spoken figure is 995 of 1,000, from the basis, not from the set sun |
| 11 | `:1199` July 200 of 300 failed; period 1 Jul to 30 Sep | July minimum missed · Resets in 8 days; $0.00 spent · $0.00 earned | July minimum missed. $0.00 spent · $0.00 earned. Resets in 8 days, period ends 30 Sep. $0.00 earned |
| 12 | `:1163` spend 420, earned 8.40 | No cap · Resets in 8 days; $420.00 spent · $8.40 earned | No cap. $420.00 spent · $8.40 earned. Resets in 8 days, period ends 30 Sep. $8.40 earned |
| 13 | `:1246` September met, October pending; period 1 Sep to 31 Oct; spend 900 | No cap · Resets in 39 days; $900.00 spent · $0.00 earned; slip "Rewards unlock after 31 Oct" | No cap. $900.00 spent · $0.00 earned. Resets in 39 days, period ends 31 Oct. $0.00 earned. Rewards unlock after 31 Oct |
| 14 | No dedicated test | The target's headline, plus "Rewards unlock after …" or "Minimum not yet met" | As the text |
| 15 | `:1365` spend 1,000, earned 40 | **$40.00** earned; $1,000.00 spent | $40.00 earned. $1,000.00 spent |
| 16 | `:1357` no as-of date | As its state, with no deadline | As its state, without the deadline clause |

### The partial-block cap

The server sets `maximum_spend_exceeded` once the headroom is less than one earning block. So a card can be "Bonus cap reached" at $995.00 of $1,000.00 (state 10). The decision:

- The picture follows the **action**: the sun sets, because the server says the bonus is spent.
- The figure stays **raw**: "$995.00 / $1,000.00". It is never rounded up to look full.
- The sheet's existing Cap target row already carries the block caption: "Counts spend in whole earning blocks, so the room left can differ by up to one block." Nothing new is added to the board row. Whether to add a row hint is an open question.

## Geometry

### Layouts

| Layout | Used for | Size at the default text size (`.large`) |
| --- | --- | --- |
| **Strip** | Rewards board rows | Full row width, about 116pt tall. The row is the frame. |
| **Paper row with print** | Account register strip | About 96pt, with a 90 × 60pt print on the trailing side |
| **Paper row with band** | Board and register rows at accessibility text sizes | A 64pt scene band above the text |
| **Paper row, plain** | Range Report "Cards" section | As today, no picture |
| **Hero** | Detail sheet header | A 3:2 print with a 6pt border |

### The scene

Every layout draws the same scene, back to front: sky, horizon warmth, rings, sun, back ridge, front ridge, crest stroke, then afterglow and dim in the set state only. Each layout sets four things:

- `lane`: the sun's horizontal range, as fractions of the width.
- `crest(x)`: the top of the back ridge at x.
- `zenith`: where the sun's centre sits at fill 1.
- `r`: the sun's radius.

Sun centre: `x = lane.lower + elapsed × lane.width`; `base = crest(x) + 0.4r`, so a sliver of the disc breaks the crest at fill 0; `y = base − fill × (base − zenith)`. When set: `y = frontCrest(x) + 0.6r`, which is hidden.

| Layout | Lane | Crest in the lane | Zenith | r | Ring spread σ |
| --- | --- | --- | --- | --- | --- |
| Strip | 0.64 to 0.94 | Flat: `C − 6pt`, within 1pt | 13pt from the top | 7pt | 0.8 |
| Print, 90 × 60 | 0.12 to 0.88 | Brand ridge | 0.16 of the height | 5pt | 0.6 |
| Band, 64pt | 0.10 to 0.90 | Flat: 0.70 of the height, within 1pt | 12pt | 6pt | 0.7 |
| Hero | 0.08 to 0.92 | Brand ridge: 0.665 of the height at the left, 0.42 at the right | 0.12 of the height | 0.045 of the width | 1.6 |
| Web face, desktop 3:2 | 0.58 to 0.92 | Brand ridge | 0.22 of the height (shipped) | 4.5% of the width (shipped) | Shipped bands |
| Web strip, phones | As Strip | | | | |

The strip's crest is flat across the lane, so equal fills sit at equal heights in every row, whatever their dates. In the hero and the print the height is measured from the local crest, so it reads as "how far between the ridge and the target line".

**Brand ridge.** Use the web SVG paths verbatim (`apps/web/src/pages/Rewards.tsx:697-702`, viewBox `0 400 1024 624`, stretched into the bottom 58% of the frame). A SwiftUI `Path` cannot be asked for y at a given x, so sample the back crest once into a static 65-point table and interpolate. The web port uses the same table.

**Strip ridges** are new and drawn relative to the measured crest line `C`, which is the top edge of the text block that sits on the ridge.

- Front ridge: its crest stays within 2pt of `C` across the full width (+1pt at 0, −2pt at 0.18, +1pt at 0.36, −1pt at 0.55, flat from 0.62). It is filled to the bottom, and the text sits on it. Crest stroke: `Crest` at 60%, 1.5pt.
- Back ridge: 4 to 12pt above `C` left of 0.60, with low peaks near 0.15 and 0.45, then flat at `C − 6pt` from 0.62 to 0.96. It never rises into the name. The name's bottom is at least 10pt above `C`.

### Rings

- Ring k (1 to 4) is drawn only when `floor(4 × fill) ≥ k`. The core glow under the disc always draws when there is a sun.
- On iOS, ring k is a soft annulus centred on the sun. It runs from `r + ρ(k − 0.35)` to `r + ρ(k + 0.05)`, where `ρ = σ × r × (0.8 + 0.4 × fill)`, with a 1pt feather on each edge so each step reads as posterised light, not a drawn line. Tune σ by eye against the web face at hero size.
- Colours: `Ring1` to `Ring4`, inner to outer. On the night sky draw rings with the screen blend mode, as web does, so they stay warm rather than olive.
- Halo opacity: `0.45 + 0.55 × fill`, multiplied by 0.7 when underexposed.
- On the strip, ring 2's outer edge must stay right of the name column (0.56 of the width). Rings 3 and 4 may pass behind the name: at 14% and 7% alpha they keep the day ink above 10:1. On the night sky they lighten the near-black only slightly.

### Strip, default text size

```
 W = 361pt (iPhone 16 with 16pt list insets), corner radius 16 (Theme.Radius.card)
┌──────────────────────────────────────────────────────────────┐   top padding 12
│ 🧳 Travel Card                                    .  o  .      │   name, line ~25, max 0.56 W
│                                                ( ( O ) )     │   sky gap 16; sun lane 0.64 W to 0.94 W
│~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~│   crest C, about 53pt
│ $184.50 to minimum                            8 days left    │   ridge margin 8, headline line ~25
│ $315.50 / $500.00 · $0.00 earned                             │   3, basis line ~17, bottom 12
└──────────────────────────────────────────────────────────────┘   about 116pt
```

| Element | Type | Ink |
| --- | --- | --- |
| Account emoji and name | Instrument Serif Italic 21pt, relative to `.title3`; at most 2 lines, then a tail truncation | `InkDay` on day skies, `InkNight` on night skies |
| Amount | IBM Plex Mono SemiBold 19pt, relative to `.title2` | `FootInk`, or `FailedInk` for a failed card |
| Action label | IBM Plex Sans 15pt, relative to `.subheadline` | `FootInk` |
| Deadline, trailing | IBM Plex Sans 13pt, relative to `.footnote`; SemiBold when urgent | `FootInkSoft`; `UrgentInk` when urgent |
| Basis line | IBM Plex Mono 13pt, relative to `.footnote`; may wrap | `FootInkSoft` |

- The headline line keeps today's `ViewThatFits` behaviour (`RewardsView.swift:920-958`): if the action and the deadline do not fit on one line, the deadline drops below. The action never wraps mid-phrase.
- Padding is `@ScaledMetric(relativeTo: .body)`: 16 horizontal, 12 vertical, 16 for the sky gap.
- **Exceptions** go on a paper slip tucked under the frame, as on the web. The slip is 8pt narrower on each side, starts 10pt under the frame's bottom edge, uses `Theme.card` and has 12pt bottom corners. Lines are IBM Plex Sans Medium 13pt with today's triangle icon and inks (`RewardsView.swift:885-897`): at most 2, then "+N more". Each line adds about 20pt. The frame's height never changes for exceptions.
- To stay near today's height, the strip leaves out the chevron that today's title line has. It also does not take the web face's issuer and type caps line or its Featured mark. See the open questions.
- Cost: about 4.7 rows fit on an iPhone 16 at the default size, against about 5 today (116 + 10pt per row, against 104 + 10pt).

### Paper row with print (register)

- `Theme.card`, radius 16, 14pt vertical and 16pt horizontal padding.
- Leading column: today's four-line content, with the same fonts as the strip but today's inks on paper (`Theme.textPrimary`, `Theme.rowSecondary`, the tone inks).
- Trailing: a 90 × 60pt print, radius 8 (`Theme.Radius.inset`), with a 0.5pt hairline at `Color.primary` 12%, top-aligned with the name. The gap to the text is 12pt.
- The headline line is narrower here (about 227pt at W 361), so the deadline usually sits below the action.

### Hero (detail sheet)

```
┌── 6pt border in Theme.card, 0.5pt hairline ──────────────────┐
│ $500.00 minimum  - - - - - - - - - - - - - - - - - - - - - - │  zenith line, dashed, at 0.12 h
│                                                  .           │
│                                       .     ( ( O ) )        │  pace line, dotted
│                              .                               │
│                     .          ___/‾‾‾‾‾‾‾\___/‾‾‾‾‾‾‾‾‾‾‾‾‾‾│  back ridge
│            .   ____/‾‾‾‾‾‾‾‾‾                                │
│  ‾‾‾‾‾‾‾‾‾‾‾‾‾‾   front ridge                                │
│  ||||||||||||||||||||||||||||||||||||||'''''''''''''''''''''  │  day ticks; today's is taller
│  1 May                                               31 May  │
└──────────────────────────────────────────────────────────────┘
```

- **Size.** The width is the sheet's content width, capped at 520pt on iPad. Inside a 6pt border the image is `(W − 12) × (W − 12) × 2/3`: 349 × 233pt on an iPhone 16. Outer radius 16, inner radius 10. The 3:2 ratio and the visible border make it read as a photographic print, not a payment card.
- **Pace line.** The locus of the sun's position at `fill = elapsed` for every elapsed value from 0 to 1. Drawn 1pt dotted in `PaceNight` on night skies and `PaceDay` on day skies. Only for the paced actions. The sun above the line is ahead and below it is behind. Nothing says so in words.
- **Zenith line.** Dashed 1pt at the zenith, labelled at its leading end with the basis target and kind: "$500.00 minimum", "$400.00 monthly minimum", "$1,600.00 next tier", "$1,000.00 bonus cap". IBM Plex Mono 11pt. Drawn only when there is a basis.
- **Day ticks.** Along the bottom of the front ridge. One tick per day for windows up to 62 days, one per week (Mondays) up to 186 days, otherwise one per month (the 1st). Past ticks are `Crest` at 70%, future ticks `FootInk` at 25%, and the as-of tick is twice as tall. The window's start and end dates sit at the two ends in IBM Plex Mono 10pt `FootInkSoft`.
- **The slip.** Below the hero, in the same clear section, on the grouped background: a caps line (issuer · type, IBM Plex Sans SemiBold 11pt tracked 0.14em, `Theme.rowSecondary`), then today's headline line, the basis line and the exceptions. The name stays in the navigation title.
- The in-frame labels are fixed-size art annotations that repeat the slip. They are hidden from VoiceOver, and hidden altogether at accessibility text sizes.

### What collapses when

| Text size | Board | Register | Sheet |
| --- | --- | --- | --- |
| xSmall to xxxLarge | Strip. Above `.large` the name wraps to 2 lines, the deadline drops below the action, and the basis line wraps. The sky and the foot grow with the text; the art never scales text. | Paper row with print | Hero and slip |
| AX1 to AX5 | Paper row with band: a full-width 64pt scene band (radius 16 on the top corners), with the text below on paper, full width | Paper row with band | Hero without in-frame labels; the slip text scales |

Estimates: the strip is about 116pt at `.large` and 150 to 170pt at xxxLarge; the band row is about 280pt at AX1 with a two-line name. **Widths:** iPhone SE (3rd generation) gives W 343, iPhone 16 gives 361 and Pro Max gives 398. On iPad the row content is capped at 640pt and centred, because the board has no readable-width limit today and a 700pt-wide strip turns into a thin ribbon.

## SwiftUI architecture

### What replaces what

| Today | Where | Becomes |
| --- | --- | --- |
| `RewardFilledRow` as the board row label | `Views/RewardsView.swift:358`, inside `boardRow` (`:353-405`) | `RewardExposureRow` (strip), or `RewardPaperRow(.band)` at accessibility sizes. Row insets, swipe actions, context menu and accessibility modifiers stay as they are. `.contentShape` uses radius 16. |
| The `RewardFilledRow` struct with `titleLine`, `actionLine`, `headlineText`, `exceptionInk` | `:809-959` | Deleted. The text pieces become small shared views (`RewardCardTitle`, `RewardCardHeadline`, `RewardCardBasis`, `RewardCardExceptions`) used by the strip, the paper rows and the hero slip. |
| `LeadingFill` | `:962-976` | Kept. The category rows in the sheet (`:1328`) still use it. |
| Sheet header `RewardFilledRow(showsChevron: false, showsTitle: false)` | `:996-1001` | `RewardExposureHero` and the slip, as one accessibility element |
| Sheet `progressRow` (stock `ProgressView`) | `:1189-1209` | Kept. Targets lists every target precisely, and a precise list is the right job for a stock control. Its tint follows the new `.complete` ink. |
| Range Report cards | `:1441` | `RewardPaperRow(.plain)` |
| Register strip | `:1717`, inside `RegisterRewardRow` (`:1698-1745`) | `RewardPaperRow(.print)` |
| `RewardTonePalette` track and fill | `Support/Theme.swift:115-148` | Ink only. `.complete` gets its own dusk ink, so it no longer shares the failed red. |
| List-wide arrival animation | `Views/RewardsView.swift:186` | `reduceMotion ? nil : Theme.Motion.arrive` |
| Snapshot row | `apps/ios/HowMuchTests/RewardsReportTests.swift:1485` | Renders the new row; see Verification |

New files: `Support/RewardExposure.swift` (the mapping), `Views/RewardExposureFace.swift` (the Canvas), `Views/RewardExposureRows.swift` (strip, paper row, hero), `Support/RewardTypography.swift` and `Fonts/`. The project lists files explicitly (`objectVersion = 56`), so add each one to `HowMuch.xcodeproj` and to the HowMuch target.

### Projection additions

Two stored properties. Nothing else in the projection changes.

```swift
// Sketch, unverified (no Xcode here).
/// The dates the deadline closes: the active month for a monthly minimum,
/// otherwise the card period containing the as-of day. Nil in range mode.
let window: ClosedRange<String>?
/// Share of `window` before the as-of day, 0...1. The as-of day is still
/// spendable, so it counts as remaining, as the deadline does.
let elapsed: Double?

static func elapsed(asOf: String?, window: ClosedRange<String>?) -> Double? {
  guard let asOf, let window,
    let span = RewardsCalendar.days(from: window.lowerBound, to: window.upperBound),
    let gone = RewardsCalendar.days(from: window.lowerBound, to: asOf)
  else { return nil }
  return min(1, max(0, Double(gone) / Double(span + 1)))
}
```

In `make(row:asOf:isRange:)`: the `monthlyMinimum` branch uses `month.start...month.end`. Every other branch uses `period.map { $0.start...$0.end }`, with the same `period` the deadline already uses (`Support/RewardRowProjection.swift:187-189`). Range returns nil.

### The mapping

`RewardExposure` is a pure value derived from the projection. It is the state table in code.

```swift
// Sketch, unverified.
struct RewardExposure: Equatable {
  enum Sun: Equatable { case none, rising, set }
  var night: Bool
  var sun: Sun
  var fill: Double        // 0...1; 0 when there is no sun
  var elapsed: Double?
  var underexposed: Bool
  var monochrome: Bool
  var paced: Bool         // the sheet's pace line

  var rings: Int { sun == .rising ? Int((fill * 4).rounded(.down)) : 0 }

  /// Nil for range rows, which draw no picture.
  init?(_ p: RewardRowProjection) {
    if p.action == .range { return nil }
    night = p.rewardType == .miles
    elapsed = p.elapsed
    monochrome = p.tone == .failed
    switch (p.action, p.fill) {
    case (.capReached(_, true), _): sun = .set; fill = 1
    case (.qualificationFailed, _), (_, nil): sun = .none; fill = 0
    case (_, let value?): sun = .rising; fill = value
    }
    underexposed = sun == .rising && (p.tone == .needsMinimum || p.tone == .neutral)
    switch p.action {
    case .minimum, .monthlyMinimum, .nextTier: paced = p.elapsed != nil
    default: paced = false
    }
  }
}
```

### `RewardExposureFace`: one `Canvas`

The face is a single `Canvas`. It is not a stack of `Shape` views.

- **One pass, one layer.** A list row needs about nine layers: sky, horizon, up to four rings, the disc, two ridges, the crest and the dim. As `Shape` views that is 10 to 12 views per row with their own identity and diffing, times every visible row. `Canvas` draws them in one immediate-mode pass and keeps the result until its inputs change. Scrolling never redraws it.
- **Geometry stays in one place.** The sun's position depends on `crest(x)`, the lane and the layout. A pure `ExposureScene(size:layout:)` computes everything and the Canvas draws it. The web port mirrors the same functions.
- **Animation without per-layer state.** The face conforms to `Animatable` with three values: across, altitude and dim. SwiftUI interpolates them and redraws only the animating rows.
- **Text stays out.** Every word is a real `Text` outside the Canvas, so Dynamic Type, Bold Text, VoiceOver and OCR keep working. The Canvas is `accessibilityHidden(true)` and `accessibilityIgnoresInvertColors(true)`, because Smart Invert must not turn a print into a negative.

```swift
// Sketch, unverified.
struct RewardExposureFace: View, Animatable {
  var exposure: RewardExposure
  var layout: ExposureLayout      // .strip(crest:), .print, .band, .hero(showsLabels:)
  var across: Double              // elapsed, or 0.6 of the lane when unknown
  var altitude: Double            // fill when rising; -0.3 once set
  var dim: Double                 // 0...1, the set state's overlay and afterglow

  var animatableData: AnimatablePair<AnimatablePair<Double, Double>, Double> {
    get { .init(.init(across, altitude), dim) }
    set { across = newValue.first.first; altitude = newValue.first.second; dim = newValue.second }
  }

  var body: some View {
    Canvas { context, size in
      let scene = ExposureScene(size: size, layout: layout, night: exposure.night)
      if exposure.monochrome { context.addFilter(.saturation(0.15)) }
      scene.drawSky(in: context, horizon: !exposure.monochrome)
      if exposure.sun != .none {
        let sun = scene.sunCentre(across: across, altitude: altitude)
        scene.drawRings(in: context, at: sun, count: Int((max(0, altitude) * 4).rounded(.down)),
          strength: exposure.underexposed ? 0.7 : 1)
        scene.drawSun(in: context, at: sun, underexposed: exposure.underexposed)
      }
      scene.drawRidges(in: context)
      if dim > 0 { scene.drawAfterglowAndDim(in: context, across: across, amount: dim) }
    }
    .accessibilityHidden(true)
    .accessibilityIgnoresInvertColors(true)
  }
}
```

### The strip row

The scene is the row's background. The crest is wherever the text block on the ridge begins, so long names and large text move the ridge rather than overlap it.

```swift
// Sketch, unverified.
struct RewardExposureRow: View {
  let projection: RewardRowProjection
  let text: RewardRowText
  var icon: String?
  var index = 0
  @State private var crest: CGFloat?
  @State private var width: CGFloat = 0
  @ScaledMetric(relativeTo: .body) private var skyGap = 16.0

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      RewardCardTitle(projection.title, icon: icon, onNight: projection.rewardType == .miles)
        .frame(maxWidth: width * 0.56, alignment: .leading)   // the sun lane stays clear
        .padding(.bottom, skyGap)
      VStack(alignment: .leading, spacing: 3) {
        RewardCardHeadline(projection: projection, text: text, surface: .ridge)
        RewardCardBasis(text: text, surface: .ridge)
      }
      .padding(.top, 8)
      .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("exposure")).minY } action: { crest = $0 }
    }
    .padding(.horizontal, 16).padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    .background {
      if let crest, let exposure = RewardExposure(projection) {
        RewardExposureAnimator(exposure: exposure, layout: .strip(crest: crest),
          key: "\(projection.cardID)|\(projection.window?.upperBound ?? "")", index: index)
      }
    }
    .coordinateSpace(.named("exposure"))
    .clipShape(.rect(cornerRadius: Theme.Radius.card, style: .continuous))
  }
}
```

If the first layout pass shows a frame without a scene, seed `crest` with an estimate (about 0.46 of the row height) rather than drawing nothing.

### Fonts

iOS bundles no custom fonts today. Add them for the card only.

- **Files.** Instrument Serif Italic, plus IBM Plex Sans and IBM Plex Mono in Regular, Medium, SemiBold and Bold: nine static `.ttf` files, about 1.3 MB. Take them from the upstream SIL OFL 1.1 releases and match the versions `apps/web` pins through `@fontsource`. Keep the OFL texts beside them in `Fonts/` and list the fonts in any in-app acknowledgements.
- **Registration.** Add the files to `UIAppFonts` in `HowMuch/Info.plist`. Read the PostScript names from the files (Font Book or `fc-scan`); do not guess them.
- **Dynamic Type.** Always `Font.custom(_:size:relativeTo:)`, so the sizes in the strip table scale with the user's setting.
- **Bold Text.** When `legibilityWeight == .bold`, step each Plex weight up one (Regular to Medium, SemiBold to Bold). Instrument Serif has a single weight and is display-sized, so it stays.
- **Missing fonts.** `Font.custom` falls back to SF silently. Add a DEBUG-only launch assertion that each name resolves through `UIFont(name:size:)`. This is a runtime guard, not a test.

### Colour assets

Add a `Face` folder to `Assets.xcassets` with **Provides Namespace** checked, and read the colours as `Color("Face/SkyDay1")` through a small `Theme.Face` accessor. The faces are prints, constant across looks and modes exactly as on the web (`apps/web/src/styles/tokens.css:77-88`). So **Any and Dark carry the same value on purpose**. Fill both explicitly, so nobody later "fixes" a missing dark value. Add a High Contrast variant where one is listed.

| Colour set (`Face/…`) | Any = Dark | Increase Contrast | Web token |
| --- | --- | --- | --- |
| `SkyDay1`, `SkyDay2`, `SkyDay3` | #EFE2CF, #EAD4AD, #E2C48F (stops 0, 0.48, 1 at 165°) | same | `--face-day` |
| `SkyNight1`, `SkyNight2` | #1C2013, #0B1710 | same | `--face-night` |
| `InkDay` | #1C1B18 | same | `--face-day-ink` |
| `InkNight`, `FootInk` | #F7F5EF | same | `--face-night-ink`, `--face-foot-ink` |
| `FootInkSoft` | #D4E2D9 | #EEF4F0 | new `--face-foot-soft` |
| `UrgentInk` | #FFD98C | #FFE7B5 | new `--face-urgent-ink` |
| `FailedInk` | #FFABAE | #FFD1D3 | new `--face-failed-ink` |
| `RidgeBack` | #2A6648 | #235741 | `--ridge-back` |
| `RidgeFront` | #1E4433 | #163527 | `--ridge-front` |
| `Crest` | #FFD98C, drawn at 60% | drawn at 100% | `--ridge-crest` |
| `SunDiscTop`, `SunDiscBottom` | #FFFDF6, #F8E6BA | same | `--sun-disc` |
| `SunRim` | #DFA050, drawn at 60% | same | `--sun-rim` |
| `SunCore` | #FFD382 | same | `--sun-core` |
| `SunCoreUnder` | #E2A95C | same | `--glow-edge` |
| `Ring1` to `Ring4` | #FFD27A at 78%, #FFA452 at 28%, #F08446 at 14%, #D8604A at 7% | same | `--face-ring-1` to `--face-ring-4` |
| `Horizon` | #FFAD5C at 17% | same | `--face-horizon` |
| `Afterglow` | #FFAD5C at 40% | same | new `--face-afterglow` |
| `Dim` | #1C1B18 at 18% (the end of a clear-to-dim gradient) | same | `--face-dim` |
| `PaceDay`, `PaceNight` | #1C1B18 at 25%, #FFD98C at 45% | 40%, 70% | none; the sheet only |

**Contrast on the faces** (WCAG relative luminance, worked by hand; confirm with the OCR snapshot and Accessibility Inspector):

| Text | Background | Ratio |
| --- | --- | --- |
| `FootInk` | `RidgeFront` | 10.0:1 |
| `FootInkSoft` | `RidgeFront` | 8.1:1 |
| `UrgentInk` | `RidgeFront` | 8.1:1 |
| `FailedInk` | `RidgeFront` at saturation 0.15 | about 6:1 |
| `InkDay` | `SkyDay3`, the darkest day stop | 10.3:1 |
| `InkNight` | `SkyNight1` | 15:1 |

Text never sits on the back ridge or across the crest stroke.

**Chrome stays in code.** In `Support/Theme.swift`, `RewardTonePalette` keeps only `ink`. Track and fill go with `RewardFilledRow`. `.complete` gets the web's `--tone-complete` dusk: light #5F5457, dark #BCAEB4, Increase Contrast light #4A4044 and dark #D6CBD0. That is 7.3:1 on white and 7.6:1 on the dark card. `.failed` keeps its red. Exceptions for capped categories therefore read in dusk, not alarm red, which matches "done, not failed". Print borders and slips use `Theme.card`.

### Performance with 20 or more cards

- `List(.plain)` is already lazy. One Canvas per realised row, with no `.blur`, `.shadow`, material, `.drawingGroup()` or `TimelineView` per row. Rings are radial gradients, the dim is a linear gradient, and monochrome is one colour-matrix filter.
- The face is `Equatable` on (exposure, layout, across, altitude, dim) and applied with `.equatable()`. `RewardsBoard` is rebuilt on every `body` (`Views/RewardsView.swift:158-160`), and unchanged cards must not redraw.
- Build ridge paths once per layout as unit paths, scale them with a transform, and keep the crest table `static`.
- Only animating rows redraw per frame: at most the visible rows (about six) for 0.6s after data arrives.
- The context-menu preview renders the same row, and the swipe action is unchanged.
- **Check:** the 28-card fixture below, flung top to bottom and back, with Instruments' Animation Hitches template. The simulator gives an indication only. Real evidence needs a device run, which needs a signed build the owner authorises.

## Motion

Timings are `Theme.Motion` (`Support/Theme.swift:180-189`). The web uses the same values through its tokens (`--dur-fill` 600ms, `--dur-standard` 320ms, `--dur-arrive` 400ms, `--stagger` 28ms).

| Moment | Animation | Reduce Motion |
| --- | --- | --- |
| A card is first shown this session | The List's existing arrival (`arrive`, 0.4s). The sun rises from fill 0 to its place with `chart` (0.6s), and rings step in as the altitude crosses each quarter. Stagger 28ms × min(index, 12). | Drawn in place. No rise. |
| Scrolled back into view | Nothing: it was already shown | Same |
| Data change in the same window (refresh, a new transaction, the as-of date stepped within the window) | The sun glides from the old (across, altitude) to the new one with `chart`. Figures crossfade in place over 0.18s with `.contentTransition(.opacity)`. | The sun jumps. Figures crossfade, since opacity is allowed. |
| The window changes (a new period or month) | The face crossfades over 0.32s (`standard`). The sun never glides backwards across the sky. | Jump |
| A refresh moves the card into a terminal cap | Once: the sun finishes its rise to the zenith over 0.6s, then sets behind the ridge while the sky dims over 0.32s | Jump to the set state |
| Tap | Scale 0.99 with `press` (0.18s), no opacity change. Today's `PressableButtonStyle` (0.97 and 0.85) is too strong for a picture. | Opacity 0.9, no scale |
| Opening the sheet | The system sheet. A zoom from row to hero is optional (see the open questions). | System |
| Idle | Nothing. No `TimelineView`, shimmer, pulse or drifting rings. | Same |

**Interpolation.** The sun interpolates in (across, altitude) space through `animatableData`, not in screen points. On the strip the crest is flat, so the glide is a straight line. In the hero it follows the ridge's shape beneath. Use `Theme.Motion.chart`, which is `.smooth` with no bounce. Never use a bouncy spring for the sun: overshoot would briefly show progress the ledger has not reached.

**No counting.** Text never counts. Use `.contentTransition(.opacity)` only. Never use `.numericText` or the register's `.rollingNumber` (`Views/Components.swift:186-195`) on the card.

**Rising once.** A lazy `List` creates rows again as they scroll, so `onAppear` alone would replay the rise. Keep the last altitude shown per card in a session-only memory, keyed by plan, card and window end. A row that appears starts from that value (or 0 the first time) and animates only if the value differs.

```swift
// Sketch, unverified.
@MainActor @Observable final class ExposureMemory {
  var shown: [String: Double] = [:]       // plan | card | window end -> altitude
}

struct RewardExposureAnimator: View {
  let exposure: RewardExposure
  let layout: ExposureLayout
  let key: String
  var index = 0
  @Environment(ExposureMemory.self) private var memory
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var altitude: Double?
  @State private var sunsets = 0

  private var target: Double { exposure.sun == .set ? -0.3 : exposure.fill }

  var body: some View {
    RewardExposureFace(exposure: exposure, layout: layout, across: exposure.elapsed ?? 0.6,
      altitude: altitude ?? target, dim: exposure.sun == .set ? 1 : 0)
      .onAppear {
        let start = memory.shown[key] ?? (exposure.sun == .set ? target : 0)
        altitude = reduceMotion ? target : start
        memory.shown[key] = target
        guard !reduceMotion, start != target else { return }
        withAnimation(Theme.Motion.chart.delay(Double(min(index, 12)) * 0.028)) { altitude = target }
      }
      .onChange(of: exposure) { old, new in
        memory.shown[key] = target
        if old.sun != .set, new.sun == .set, !reduceMotion { sunsets += 1; return }
        withAnimation(reduceMotion ? nil : Theme.Motion.chart) { altitude = target }
      }
      // The sunset, once per crossing: rise to the zenith, then set and dim.
      .keyframeAnimator(initialValue: SunPose(altitude: altitude ?? 0, dim: 0), trigger: sunsets) { face, pose in
        face.posed(altitude: pose.altitude, dim: pose.dim)
      } keyframes: { _ in
        KeyframeTrack(\.altitude) {
          CubicKeyframe(1, duration: 0.6)       // Theme.Motion.chart
          CubicKeyframe(-0.3, duration: 0.32)   // Theme.Motion.standard
        }
        KeyframeTrack(\.dim) {
          LinearKeyframe(0, duration: 0.6)
          CubicKeyframe(1, duration: 0.32)
        }
      }
      // After the keyframes the card must rest at `target` (-0.3) with dim 1.
      // Confirm on device what a trigger-driven keyframeAnimator shows once it
      // finishes, and set `altitude` without animation if it falls back.
  }
}
```

Also fix the list-wide `.animation(Theme.Motion.arrive, value: model.rewardsPhase)` (`Views/RewardsView.swift:186`), which does not check Reduce Motion today.

## Accessibility

- **One element per card, as today.** The label is the card name, the value is `RewardRowText.accessibilityValue`, the hint is "Shows details.", and the custom actions are Edit Rewards and Hide (`Views/RewardsView.swift:396-404`). The register row keeps "Rewards, <name>" and its hint (`:1720-1722`). The slip is part of the same element. The face, emoji and every in-frame label are hidden.
- **Nothing new is spoken by default.** The value string stays pinned by `testAccessibilityValueStatesTargetProgressAndDeadline` (`apps/ios/HowMuchTests/RewardsReportTests.swift:1413`). The deadline clause already says how much of the window is left, so no "per cent elapsed" clause is added and no pace judgement is spoken. The issuer, newly visible in the sheet, is offered through `accessibilityCustomContent("Issuer", issuer)` in the More Content rotor.
- **Dynamic Type.** Every font is relative to a text style, and padding uses `@ScaledMetric`. The strip grows with its text. At accessibility sizes, every row becomes the paper row with a band, so text never sits on fixed-ratio art.
- **Contrast on the faces.** See the contrast table. Text sits only on uniform sky or on the front ridge, and never across the crest stroke or over rings 1 and 2.
- **Increase Contrast.** Today's 1pt outline at `Color.primary` 30% stays, on the strip and on the print. The High Contrast colour sets darken the ridges and lighten the foot inks. The crest stroke draws at 100%, and the pace line at 70% on night skies and 40% on day skies.
- **Differentiate Without Colour.** Each state differs in shape as well as colour: sun up, set, absent or monochrome, plus four ring counts, plus the headline words.
- **Smart Invert.** Faces ignore invert, like photographs.
- **Reduce Transparency.** Nothing to change: there is no material, and figures stay on opaque surfaces.

## Web parity

The web face already draws this scene. Parity means the web takes the iOS row's rules and the new picture rules, so both platforms show the same state for the same report.

### 1. Port the projection, tests first

Per `AGENTS.md`, isolation is justified here. The web's R1 helpers (`cardTone`, `capIsPrimary`, `cardFill` at `apps/web/src/pages/Rewards.tsx:481-505`) have concrete bugs that the browser recipe only catches for states its fixture reaches:

- an intermediate cap is marked complete;
- a failed qualification shows before its month closes;
- the server's `minimum_spend_progress` drives the fill.

The rounding and Singapore-day rules have edge cases no fixture reaches.

- **Write the tests first.** Create `apps/web/src/lib/reward-row-projection.test.ts` before any implementation. Port every case of `RewardRowProjectionTests` with the Swift test name in each test title and the same hand-derived expected strings, plus the elapsed cases below. Configure the same SGD format the Swift tests use (`configureMoney` in `apps/web/src/lib/money.ts`). Run it red against a stub that exports only the types.
- **Then the module.** `apps/web/src/lib/reward-row-projection.ts` exports `projectRow(row, asOf, isRange)`, `rowText(projection)`, `boardSummary(report, projections)`, `exposure(projection)`, the crest table and the scene helpers. Civil dates use string parts and `Date.UTC`, never a local `Date`.
- **Run it** with `bun test apps/web/src/lib/reward-row-projection.test.ts`, and again under `TZ=America/Los_Angeles` and `TZ=Pacific/Kiritimati`.

### 2. `Rewards.tsx`

- Delete `cardTone`, `capIsPrimary` and `cardFill`. `RewardCard` (`:543-569`) builds one projection per row and sets:
  - `data-tone` (needs, earning, complete, failed or neutral, from the projection);
  - `data-sun` (rising, set or none), `data-rings` (0 to 4), `data-exposure` (full or under) and `data-mono`;
  - inline `--rw-p` (fill), `--rw-t` (elapsed, or 0.6) and `--rw-base` (from the crest table at the sun's x).
- The slip (`RewardTile`, `:682-792`) replaces the R2 placeholder at `:718` with the headline: the amount in IBM Plex Mono, the label, and `<span className="rw-deadline" data-urgent>`. Then come the basis line and the exceptions (at most 2, then "+N more").
- The two `ExposureMeter`s, the Spend, Eligible and Value stats, and "Consider another card" move into the disclosure, renamed **Targets, periods and tiers**. On desktop the flag list stays in the slip. On phones it moves into the disclosure, matching iOS, which keeps categories in the sheet.
- The hero's R2 placeholder (`:210`) becomes the ported summary line, for example "2 below minimum · 1 capped".

### 3. `rewards-board.css` and `tokens.css`

- **Tokens.** Register `@property --rw-t` beside `--rw-p` (`tokens.css:16`). Add the constant face tokens `--face-foot-soft`, `--face-urgent-ink`, `--face-failed-ink` and `--face-afterglow` with the values in the colour table. Faces stay identical across Dusk Ridge, Ridge Charcoal and Overexposed: the looks differ only in chrome colour.
- **Sun and halo** (`:533-565`): position from the lane and base.

  ```css
  /* Sketch. --rw-t, --rw-p and --rw-base are set inline from the projection. */
  .rw-face-sun {
    left: calc(58% + var(--rw-t) * 34%);
    top: calc(var(--rw-base) - var(--rw-p) * (var(--rw-base) - 22%));
  }
  ```

  The halo's `circle at` follows the same x and y.
- **Rings.** Gate them with `data-rings`, for example by setting `--face-ring-3` and `--face-ring-4` to transparent under `[data-rings="2"]`, and keep the shipped band geometry.
- **States.** `[data-sun="set"]` replaces the `[data-tone="complete"]` rules (`:649-664`), so a set sun follows the action, not `maximum_spend_exceeded`. `[data-mono]` replaces `saturate(0.35)` (`:666-668`) with 0.15 and hides the sun and halo. `[data-exposure="under"]` takes over the `needs` core rule (`:644-646`) and multiplies the halo by 0.7. `[data-sun="none"]` hides both.
- **Phones** (`@media (max-width: 720px)`, `:1087`): the card becomes the strip. The name sits on the sky; the headline and basis line sit on the ridge foot, with the front ridge drawn as the foot's background extended upward. The sun is positioned inside the sky area with the strip's lane and zenith. The slip carries exceptions only. This replaces the 21:9 face.
- **Motion.** Transition `--rw-p` and `--rw-t` over `--dur-fill`; the existing `rw-expose` arrival stays. When a refresh moves a card into the set state, a one-shot `data-just-set` runs a `rw-sunset` keyframe (`--dur-fill` then `--dur-standard`). A changed window crossfades instead of gliding back. The reduced-motion tokens already zero every duration (`tokens.css:102-108`).

### 4. Not in this slice

The web board keeps its own Arrange orders (Manual, Name, Reward value, Spend) and has no detail sheet, so there is no web pace line or hero. The `/rewards/:cardId` edit page could take the hero later.

## Verification

iOS checks run on the Mac runner through `scripts/ios-xcodebuild.sh` and the Simulator (see `apps/ios/AGENTS.md`). Linux cannot run them. Store every artifact under `.amp/in/artifacts/rewards-exposure/{ios,web}/`, which overrides the older paths in the recipes.

### Failure modes first

| # | Failure mode | Caught by |
| --- | --- | --- |
| 1 | Picture and figure disagree: the sun height comes from anything but `fill`, or `fill` from server progress fields | iOS: the existing projection tests, where fill and basis share one source. Web: the port's tests, written first. E2E: fixture cards at fills 0.32, 0.63, 0.79 and 1 |
| 2 | Web precedence wrong: intermediate cap set as complete, failure shown before its month closes, rewards implied unlocked | The port's tests, written first; E2E cards E, J, K and L |
| 3 | `elapsed` wrong: device or browser outside Singapore, the month window confused with the period, an as-of date outside the window, month lengths | **Isolated tests, written first** (below). E2E rarely shows it: the sun is a few points off. |
| 4 | Equal fills at different heights across rows, because the strip's crest is not flat in the lane | E2E: cards A and B share $315.50 / $500.00 at different dates. Measure both sun centres on the screenshot; they must match within 1pt. |
| 5 | Text illegible on the art: rings behind the name, ink on a light sky | The existing OCR snapshot test, retargeted; E2E screenshots in light, dark, AX3 and Increase Contrast |
| 6 | VoiceOver drifts: the art becomes focusable or the value string changes | The existing pinned value test (`:1413`); an E2E accessibility dump showing one element per card |
| 7 | The rise replays on every scroll, or plays under Reduce Motion | E2E recordings |
| 8 | The sunset plays on appear instead of only when a refresh crosses a cap | E2E: open a board with a capped card (no sunset), then push another card over its cap (one sunset) |
| 9 | Overshoot shows progress the ledger has not reached | E2E recording at 60fps, reviewed frame by frame where each glide ends |
| 10 | Fonts not bundled, falling back to SF silently | E2E screenshots and the DEBUG launch assertion |
| 11 | Scroll hitches with 20 or more cards | E2E with the 28-card fixture and Instruments; a device run by the owner |
| 12 | Dynamic Type clips text in a fixed frame | E2E at AX3; the existing snapshot at `.accessibility1` |
| 13 | The partial-block cap reads as false | E2E card G, checked against the rule above |

### Isolated tests: only these, written before the implementation

**iOS, in `RewardRowProjectionTests`:**

1. The monthly minimum uses the month as its window. With an August to October period, September pending and as-of 23 Sep, the expected `elapsed` is 22/30, not the period's 53/92.
2. An as-of date after the window's end (the "Period ended" case) gives 1.
3. A device zone outside Singapore gives the same value. Reuse the zone pattern of `testDaysLeftDoNotDependOnTheDeviceZone` (`:1346`).
4. No as-of date, and range rows, give nil.

**Web:** the port's suite, as described in Web parity, plus the same four cases and the two `TZ` runs.

Do not write tests for the mapping table (E2E reaches every row through the fixture), geometry constants, colour values, font names or view structure.

**Existing tests to retarget** (keep their intent and expectations; these are not new tests):

- `testStatusRowsRenderLightDarkAndLargeText` (`apps/ios/HowMuchTests/RewardsReportTests.swift:1422-1506`): render `RewardExposureRow` at `.large`, and the band row at `.accessibility1`. Its OCR expectations stay the same. OCR finding the text in five appearances is the legibility proof.
- The detail sheet snapshots (`:651`, `:680`, `:837`) now render the hero and slip, with unchanged expectations.
- `apps/web/src/lib/rewards-tile.test.ts`: the historical tile still reads the cutoff period's minimum. The meters and stats move into the disclosure but stay in the markup, so its positive and negative assertions stand. Do not weaken them.

### States fixture

Add `fixtures/rewards-exposure-states.json`, a Rewards Tracker export. An import replaces the stored card set, so it includes Travel Card. Every card is bound to `acct-credit`. The demo ledger's Travel Card spend is $26.40 in March (11 Mar, red flag), $488.90 in April (12 Apr, red) and $315.50 in May (4 May $228.90 blue, 13 May $86.60 red). As of **24 May 2026**, a calendar card has 8 days left and `elapsed` = 23/31 = 0.742.

Expected values are worked out by hand from those numbers. Before taking screenshots, confirm each one against `GET /api/reports/rewards?plan_id=local-plan&to=2026-05-24`. If the server disagrees, the server is right: change the card's thresholds and record why. Never quietly change an expectation.

| Card | Configuration | Expected headline · deadline | Expected basis | Picture |
| --- | --- | --- | --- | --- |
| A Exposure Below | Cashback, calendar, minimum 500, rate 1 | $184.50 to minimum · 8 days left | $315.50 / $500.00 | Fill 0.631, 2 rings, underexposed, across 0.742 |
| B Exposure Urgent | Cashback, billing day 26, minimum 500 | $184.50 to minimum · 2 days left, urgent | $315.50 / $500.00 | Fill 0.631, across about 0.93. Confirm the period is 26 Apr to 25 May. |
| C Travel Card | As today: miles, minimum 200, Dining 4, Online 3 | Minimum met · Resets in 8 days | $315.50 / $200.00 · 1,033 miles earned | Zenith, 4 rings |
| D Exposure Headroom | Cashback, maximum 1,000 | $684.50 left before bonus cap · 8 days left | $315.50 / $1,000.00 | 0.316, 1 ring, no pace line in the sheet |
| E Exposure Tier | Miles, tiers at 0 and 400 | $84.50 to next tier · 8 days left | $315.50 / $400.00 | 0.789, 3 rings |
| F Exposure Capped | Cashback, maximum 300, rate 1 | Bonus cap reached · Resets in 8 days | $300.00 / $300.00 · … · $15.50 beyond cap | Set, dimmed |
| G Exposure Block | Cashback, maximum 314, earning block 5 | Bonus cap reached · Resets in 8 days | $310.00 / $314.00 · … · $1.50 beyond cap | Set, with a raw figure under 100%. Confirm `counted_spend` 310 and `maximum_spend_exceeded`. |
| H Exposure Top | Cashback, minimum 300, one tier at 300 | Highest tier active · Resets in 8 days | $315.50 spent · … | Zenith, 4 rings |
| I Exposure Open | Cashback, no minimum or cap | No cap · Resets in 8 days | $315.50 spent · … | No sun |
| J Exposure Failed | Miles, 3-month period from 1 Mar, monthly minimum 100 | March minimum missed · Resets in 8 days | $830.80 spent · … | Monochrome, no sun |
| K Exposure Monthly | Cashback, 3-month period from 1 Apr, monthly minimum 400 | $84.50 to monthly minimum · 8 days left | $315.50 / $400.00 | 0.789, 3 rings, underexposed; sheet ticks 1 May to 31 May |
| L Exposure Locked | Cashback, 3-month period from 1 Apr, monthly minimum 300 | No cap · Resets in 38 days, slip "Rewards unlock after 30 Jun" | $315.50 spent · … | No sun. Confirm the month list and status. |
| M Exposure Category | Miles, minimum 200, Online capped at 200 | Minimum met · Resets in 8 days, slip "Online over cap" | $315.50 / $200.00 · … | Zenith |
| N A long name, such as "Exposure Long Name Preferred Platinum Rewards" | As A | As A, name on two lines | As A | As A, with the crest lower |

The performance variant (`fixtures/rewards-exposure-states-28.json`) holds each card twice.

### iOS recipe: `.cursor/skills/verify-howmuch/features/ios-rewards.md`

**First, fix stale lines.** The recipe predates the filled-rows board. The board has no date-range chip and no Group chip, because groups live in Range Report. The empty state reads "No Reward Cards", not "No reward cards in this range.". "Tap the rewards bar" becomes "tap the rewards row".

**Then add these sub-features:** `ios-rewards-exposure-states`, `ios-rewards-exposure-sheet`, `ios-rewards-exposure-motion`, `ios-rewards-exposure-register` and `ios-rewards-exposure-accessibility`. Steps:

1. **Set-up** (not under test). Launch with `control-howmuch launch` and pass `doctor`. Import the states fixture through web **Settings → Rewards import**. Sign the Simulator in, and enable Simulator accessibility as `apps/ios/AGENTS.md` describes.
2. **States.** Rewards → Featured menu → **All Cards**. Today menu → **Choose Date…** → 24 May 2026 → **Done**. For each card, screenshot the row and dump its accessibility element. Compare the text and value with the fixture table and the state tables. Measure the sun centres of A and B.
3. **Sheet.** Open A, where the sun is below the pace line because fill 0.631 is less than elapsed 0.742. Then open K (month ticks), D (no pace line), F (set) and J (monochrome). Screenshot each hero.
4. **Appearances.** Screenshot A, C, F, I and J again:
   - dark: `xcrun simctl ui "$UDID" appearance dark`;
   - AX3: `xcrun simctl ui "$UDID" content_size accessibility-extra-extra-extra-large`, which must give paper rows with bands;
   - Increase Contrast: Settings → Accessibility → Display & Text Size, or `simctl ui` where the installed Xcode supports it.
5. **Motion** (record with `xcrun simctl io "$UDID" recordVideo`). Relaunch and open Rewards: each sun rises once, staggered. Scroll to the end and back: no replay.
6. **Register glide and persisted write** (record). This step uses a fresh stack with `fixtures/rewards-tracker-export.json`, so the register shows one row. Open Accounts → Travel Card. Today's month has no demo spend, so the row reads "$200.00 to minimum · N days left" with no rings. Add a transaction: $100.00, payee "Exposure check", today. Back in the register, the sun glides to half height with two rings and the row reads "$100.00 to minimum". Persisted proof:
   - `control-howmuch http GET "/v1/plans/local-plan/transactions"` lists the transaction;
   - `control-howmuch http GET "/api/reports/rewards?plan_id=local-plan&account_ids=acct-credit"` shows `total_spend` 100 against `minimum_spend` 200.
7. **Sunset** (record, states fixture, as of today). Card F reads "$300.00 left before bonus cap". Add $320.00 to Travel Card. When the board refreshes, F's sun rises and sets once and the row reads "Bonus cap reached". Other cards glide; none set except F and G. Reopen the board: no replay.
8. **Reduce Motion** (record). Turn on Settings → Accessibility → Motion → Reduce Motion and repeat step 6 with $50.00. The sun jumps with no glide, and step 7's sunset does not animate.
9. **Accessibility dump.** One element per card, labelled with the card name, valued with the table string, and nothing for the art.
10. **Performance.** With the 28-card fixture, fling the board with Instruments' Animation Hitches template running. Record the simulator's limits, and leave the device check to the owner.

**Proof.** `RECORD.md` holds:

- the revision: `git rev-parse HEAD`, plus a diff hash if the tree is dirty;
- the fixture checksum, the Simulator model and the iOS version;
- the exact commands and steps, expected against observed.

Also save:

- screenshots named `{card}-{appearance}.png` and `hero-{card}.png`;
- recordings `load.mp4`, `register-glide.mp4`, `sunset.mp4` and `reduce-motion.mp4`;
- accessibility dumps `ax-board.txt` and `ax-register.txt`;
- the GET JSON.

A screenshot alone does not prove step 6: the GET output does.

### Web recipe: `.cursor/skills/verify-howmuch/features/rewards.md`

- **Open filled.** The face's headline now reads "Minimum met · Resets in 8 days" with the basis line. "Full-period minimum met" moves inside **Targets, periods and tiers**.
- **New `rewards-exposure-states`.** Import the states fixture through Settings → Rewards import and open `/rewards?to=2026-05-24`. For each card, check the slip text and the `data-sun`, `data-rings`, `data-exposure` and `data-mono` attributes against the fixture table, at 1440 × 900 (3:2 face) and 390 × 844 (strip). Screenshot Dusk Ridge light and dark, plus one other look. The faces must be pixel-identical across looks; only the chrome differs.
- **Motion.** Step the as-of date with **Next day** and record a Playwright video: the sun glides and the figures settle without counting. Under `page.emulateMedia({ reducedMotion: "reduce" })`, the first frame already shows the final `--rw-p`.
- **Proof** goes in `.amp/in/artifacts/rewards-exposure/web/`, with the same `RECORD.md` fields.

## Open questions for the owner

1. **Sun across the sky.** Keep time on the horizontal, so the sun moves right as the window passes (specified)? Or pin the sun at one point, as the web face does today, and leave time to the deadline text?
2. **Pace line on the board.** Only in the sheet (specified), or also on the board rows?
3. **Register.** A paper row with a thumbnail print (specified), or the full strip, as on the Rewards tab?
4. **What the strip leaves out.** It drops today's chevron and does not take the web face's issuer and type caps line ("DBS · MILES") or Featured mark, to stay near today's row height. Want any of them? The caps line costs about 13pt per row.
5. **Earned.** The strip keeps the earned amount inside the basis line, as today. The web face shows it large in the corner. Should it be large on the phone too?
6. **Partial-block cap.** Leave the row as specified (a set sun with the raw figure, and the sheet explains blocks)? Or add "Within one block of the cap" to the row?
7. **Failed look.** A monochrome print with no sun (specified, which keeps text contrast)? Or the concept's milky fog, which needs different inks on fogged night skies?
8. **Day faces in dark mode.** Keep prints identical in both modes, as the web does today? Or dim day skies by about 10% in dark mode on both platforms?
9. **Fonts on iOS.** Bundle Instrument Serif and IBM Plex for the card only now (about 1.3 MB) and decide on app-wide use later?
10. **iPad.** Cap the rows at 640pt (specified), or lay strips out in a two-column grid at regular width?
11. **Zoom from row to sheet.** Try `matchedTransitionSource` with `.navigationTransition(.zoom)` on a device, and keep it only if the sheet keeps its content-height detent? Or stay with the plain sheet?
12. **An existing VoiceOver repeat.** Cards with no basis (Highest tier active, No cap, failed) speak the earned amount twice. Fix it in this change, with a failing test first, or leave it?
