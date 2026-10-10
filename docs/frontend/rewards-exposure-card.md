# Rewards Exposure card

Implementation spec, version 3 ("Sun Arc v3: two journeys"). It replaces the iOS Rewards progress fill (`RewardFilledRow`) with the Exposure card, and moves the web board's face onto the same rules, so a card reads the same on both platforms. Version 3 follows the owner's answers on 7 Oct 2026 to the version 2 lab page: a warm white marker in light mode, a lighter green ground, and different journeys for the minimum and the cap. This slice has no code. The Swift and TypeScript below are sketches, unverified because this machine has no Xcode.

Read it with [the agreed filled-rows spec](../plans/rewards-filled-rows-agreed-spec.md). That spec still owns what a row says: precedence, wording, rounding, deadlines, ordering and the summary line. This document owns how the card looks and moves. Paths are relative to the repository root. iOS paths without a prefix are under `apps/ios/HowMuch/`.

## Changes from version 2

| Version 2 | Version 3 | Why |
| --- | --- | --- |
| One exposure scalar `e` drove everything: the way to the minimum took the left 60% of the width and the way to the cap the rest | Two journeys. The minimum journey is horizontal (`h`, the fill). The tier and cap journey is vertical (`v`, the sun's height). | Owner: "Minimum is left to right. Cap is sun rising from just above the ground to all the way off screen when met/exceeded. Different." |
| The sun rode one arc, partly below the horizon until the minimum, then climbing as it moved right | In the minimum journey the sun sits on the horizon as a half disc and rides the marker between 0.07 and 0.85 of the width. Past 0.85 it lifts to just clear of the ground while the last of the band fills. At the minimum it rests at 0.85, just above the ground, and from then on only rises. | As above |
| A next tier was part of the headroom stage, from 0.6 towards 1 | Approaching a tier lifts the sun from rest towards halfway, and a reached tier leaves it there. A cap after the tier carries on from halfway to the top. | Owner: "For tiers let the sun rise halfway and stay there" |
| Meeting the minimum jumped `e` forward, because the cap stage read counted spend from zero | The cap climb is measured from the minimum (or from the reached tier), so on the day the minimum is met the sun rests at the foot of its climb. No jump. | Follows from the owner's cap journey |
| The merged ridge lifted through stage 2 | The merged ridge stays put. The sun alone tells the climb. | One read per journey; the ridge would encode the cap twice |
| A capped card was the whole band lit with a bloom, the sun high at the right | The sun has climbed off the top edge. The sky is at its brightest and a glow pours down from the top edge. | Owner: "all the way off screen when met/exceeded" |
| The marker sat on a lane that ended at the sun's column | The marker stands at exactly `h × W`, so a squint reads the true fraction. The sun rides it while it can and the lit edge falls off evenly either side. | The picture must not bend the figure |
| Light-mode marker umber on the sky and dark on the ridges | Warm white #FFF8E6 at 85% with a faint dark edge, on the sky and the ground alike | Owner: "warm white is ok" |
| Light-mode ground in deep greens, light foot ink and a foot scrim | Lighter, sunlit greens (#A9D6B1 and #86C396), dark foot ink and no scrim. The urgent deadline is a dark umber and the failed headline a dark red. | Owner: "lighter green would be less jarring" |
| Rings stepped in one by one from the sunrise point | Four soft rings that grow continuously with `v`, around a sun that is always haloed | The cap journey is one smooth climb |
| No projection additions | The projection gains two plain amounts: `minimumAmount` and `reachedTierThreshold` | The climbs start at the minimum or the reached tier, which the projection did not carry |
| The strip's target horizon rose at the right | Level across the strip | The minimum journey stays horizontal, and the climb gets about 41pt instead of 26pt |

**Still standing from version 2.** Across the card is never time: no pace line, no day ticks. The marker is the brand mark's faint vertical hairline (on the hero and the web face; the phone cut of 10 Oct 2026 drops it from the strip and the band). The ridge pair's gap is what is left to the minimum. "Featured" is a word in a caps line, never a glyph. The strip is about 114pt since the phone cut. Faces follow the appearance: daytime faces in light mode, the night and dusk prints in dark mode. Capped is done, not failed. Every word and VoiceOver string is unchanged.

## Goal and non-goals

**Goal.** Each card becomes a small photograph: a sky, a pair of ridges and a sun. Spend exposes it from left to right until the minimum is met, and then lifts the sun until the cap is met.

- **Two journeys, never mixed.** Left to right is the way to the minimum: `h`, from 0 to 1, the fill of the minimum basis. Up is the way past it, through a tier and on to the bonus cap: `v`, from 0 to 1. Neither is ever time.
- **The light is the read in the minimum journey.** The art is lit from the left edge up to the progress marker and underexposed to its right, with a short soft falloff, so a squint reads "about a fifth of the way".
- **The marker is the definitive point.** A faint vertical hairline at the lit edge, `x = h × W`, like the line in the brand mark. It exists only in the minimum journey.
- **The sun is the figurehead.** It peeks over the horizon at the marker and rides it. Once the minimum is met it rests just above the ground at 0.85 of the width. Tiers lift it halfway. The cap lifts it off the top edge.
- **The ridge pair tells what is left to the minimum.** The upper line is the target horizon and the lower line the spend horizon. The gap between them is what is left to the minimum. They meet when it is met and stay put from there.
- **States.** Capped is the brightest state: done, not failed. Failed is overcast and monochrome, with no sun. A card with nothing to chase sits in an even, calm light, with the sun resting just above the ground and no marker.
- Every word and figure the current row shows stays, unchanged, from `RewardRowText`. The picture replaces the coloured fill and nothing else. The printed figures are always the projection's; `h` and `v` are art only.

**Non-goals.**

- No server or calculator change. The projection gains two plain amounts it reads from the calculation the report already carries (see Picture data); nothing printed or spoken reads them.
- No time inside the art: no pace line, no day ticks, no sun that follows the calendar.
- No change to precedence, wording, rounding, deadlines, ordering, the summary line or the VoiceOver strings.
- No Apple Wallet look: no chip, no masked number, no network mark, no ID-1 ratio, no stacked pile of cards, no flip.
- No count-up or rolling digits, and no idle animation.
- No widget or Live Activity in this slice. The paper row below is the likely widget layout later.
- No iOS restyle to Dusk Ridge chrome (plum and warm paper). Faces follow the appearance (daytime faces in light mode, the night and dusk prints in dark mode) and, within a mode, look the same in every look, on both platforms. The chrome around them stays iOS's own.
- No daily spend series. The ridge pair borrows the Spend Ridge concept's two lines, not its data. The literal reading (cumulative spend by day) is phase two; see The ridge pair.
- No per-month film strip (the "Contact Strip" concept). It stays a later candidate for the sheet's Qualification section.
- The detail sheet keeps its sections (Targets, Tiers, Qualification months, Categories, Periods). Only its header changes.

## What the card communicates

### Two journeys

One pure mapping turns the projection into a stage and two picture values, `h` and `v`, both from 0 to 1:

- **`h`, across.** The share of the way to the minimum: the `fill` of the minimum or monthly-minimum basis. The art is lit from the left edge to `x = h × W`, the marker stands there, and the sun sits on the horizon there. Once the minimum is met, or when the card has none, `h` is 1: the whole band is lit and the marker is gone.
- **`v`, up.** How far the sun has climbed in its column: 0 resting just above the ground, 0.5 halfway, 1 fully off the top edge.
  - **The cap alone.** `v = (counted − minimum) / (cap − minimum)`, clamped, from 0 when there is no minimum. It is measured from the minimum, not from zero, so the climb starts on the day the minimum is met.
  - **A tier.** Approaching it, `v = 0.5 × (spend − minimum) / (tier − minimum)`: the sun rises halfway by the time the tier is reached and stays there. After a reached tier the cap journey continues from halfway: `v = 0.5 + 0.5 × (counted − tier) / (cap − tier)`. A top tier with nothing further rests at 0.5.
  - **Capped** (met, exceeded or within a partial block) is 1, the brightest.

The journeys never share a value: while `h` is below 1, `v` is 0, and while `v` is above 0, `h` is 1. Two more quantities are derived from them and never stored:

- **The sun's lift.** From `h` 0.85 to 1 the sun lifts from the horizon to just clear of the ground while the last of the band fills: `lift = clamp((h − 0.85) / 0.15)`. It exists so that the hand-over from one journey to the other is continuous.
- **The ridge gap.** `1 − h` of the full gap.

These are picture coordinates, not figures. They are never printed, spoken or turned into words. The basis line and the spoken percentage stay the projection's, unchanged. So a cap card that says "$650.00 of $1,000.00, 65 per cent" with a $500.00 minimum shows its sun 0.3 of the way up its climb: the climb starts at the minimum, and the figure does not.

### The mapping, checked against the projection

Actions in the projection's precedence order (`Support/RewardRowProjection.swift:215-275`). "The column" is the sun's resting `x`, 0.85 of the width (see The sun's path). `minimum` is `minimumAmount`, `tier` is `reachedTierThreshold` and `threshold` is the next tier's, which is `basis.target` (see Picture data). Every ratio is clamped to 0…1.

| # | Action | Basis | Stage | `h` | `v` | Marker | Sun | Ridges | Light |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | `qualificationFailed` | None; `fill` nil | Failed | 0 | 0 | None | No sun | The brand pair, apart | Overcast, monochrome |
| 2 | `monthlyMinimum` | Month spend / month minimum | Gate | `fill` | 0 | `x = h × W` | On the horizon at `clamp(h, 0.07, 0.85)`; lifting from `h` 0.85 | Gap `1 − h` | Lit to the marker |
| 3 | `minimum` | Raw spend / minimum | Gate | `fill` | 0 | `x = h × W` | As 2 | Gap `1 − h` | Lit to the marker |
| 4 | `nextTier` | Raw spend / next threshold | Climb | 1 | `0.5 × (spend − minimum) / (threshold − minimum)`; with a tier already reached, 0.5 | None | In the column at `v` | Merged | The whole band, brightening with `v` |
| 5 | `capHeadroom` | Counted spend / cap | Climb | 1 | `(counted − minimum) / (cap − minimum)`; after a tier, `0.5 + 0.5 × (counted − tier) / (cap − tier)` | None | In the column at `v` | Merged | As 4 |
| 6 | `capReached`, terminal or not | min(counted, cap) / cap, but `fill` pinned to 1 (`:255`) | Capped | 1 | 1 | None | Off the top | Merged | The brightest: the full gold and the pour from the top edge |
| 7 | `topTier` | None; `fill` pinned to 1 | Rest | 1 | 0.5 | None | Halfway | Merged | As 4 |
| 8 | `minimumMet` | Spend / minimum, `fill` 1 | Rest | 1 | 0 | None | Resting | Merged | The whole band lit |
| 9 | `noTarget` | None; `fill` nil | Calm | 1 | 0 | None | Resting | The brand pair, apart | Even and softer |
| 10 | `range` | None | No picture | | | | | | |

What the check found:

- **A tier is a climb, never part of the minimum journey.** `nextTier` fires only after the minimum branch has passed (`:224-236`: spend has reached the calculation's minimum, or there is none). So its picture starts where the minimum journey ends: the whole band lit and the sun resting in its column. The repository's `fixtures/rewards-account-config.json` has exactly that shape: a minimum of 100 and one tier at 1,000.
- **No jump at the minimum.** Version 2's cap stage read counted spend from zero, so meeting the minimum jumped the sun forward. Measured from the minimum, the climb is at 0 on the day the minimum is met. Counted spend can lag raw spend by up to one earning block just after it, so the ratio clamps at 0 instead of dipping below.
- **Nothing falls within a period.** As spend grows, `h` and `v` never decrease. The minimum hands over to the climb at `v` 0, the approach to a tier hands over to the reached tier at 0.5, and the reached tier hands over to the cap climb at 0.5. Only a refund, or a new period or month, brings a value down (see Motion).
- **The report's minimum moves with the tiers.** The server applies the threshold of the level in force as the minimum (`apps/api/src/rewards/engine/utils/spending-tiers.ts:101`) and reports it (`engine/simple-calculator.ts:418`). So `minimumAmount` is the card's own minimum until a tier is reached, and that tier's threshold from then on. The climbs use it only while no tier is reached, and use `reachedTierThreshold` after, which is why the projection carries both.
- **The report's cap moves with the tiers too.** Caps describe the level being approached (`spending-tiers.ts:148`). On the fixture card the reported `maximum_spend` is 2,400 only below the minimum and 3,000 from the moment the minimum is met. The cap climb uses the reported cap, as the basis does, and never reads a level's cap itself.
- **A tier at the minimum is reached with the minimum.** With a minimum of 300 and one tier at 300, spend of 300 meets both at once and the card is a top tier at 0.5, or climbing from 0.5 to a cap. The sun lifts clear and climbs to halfway in one glide. Nothing falls.
- **More than one tier.** Between tiers the sun stays at halfway: the approach to a second tier reads 0.5, because once a tier is reached the one threshold the projection carries is that tier's, and the sun must never sink. See open question 14.
- **An intermediate cap is still a tier climb.** `nextTier` with the `tierCapReached` exception climbs towards halfway; only the slip says the current tier's cap is reached. Web R1 marks it complete today; that is a bug.
- **The partial-block cap is capped.** `capReached` pins `fill` to 1 while the basis shows 995 of 1,000. The picture follows the action: `v` 1. The figure stays raw.
- **Tone changes ink, not geometry.** The `earning` to `neutral` downgrade for an unqualified card (`:278-280`) leaves the pose alone. Only the minimum journey's amber sun disc follows the needs-minimum state.
- **Exceptions are words.** Locked rewards ("Rewards unlock after 31 Oct") and withheld rewards ("Minimum not yet met") leave the picture as the action draws it. See open question 2.
- **No as-of date** changes nothing in the picture, because nothing in it is time. Only the deadline text drops.

### Picture data

| Picture value | Needs | Source | Added |
| --- | --- | --- | --- |
| `h` | The fill of the minimum or monthly-minimum basis | `fill` (`Support/RewardRowProjection.swift:172`): raw spend over the minimum, or month spend over the month's minimum | Nothing |
| `v` toward a tier | Raw spend, the next threshold, the minimum | Spend and threshold: the `.nextTier` basis (`:235`). The minimum is not in the projection once the minimum branch has passed. | `minimumAmount` |
| `v` toward the cap | Counted spend, the cap, the minimum, and the reached tier's threshold if any | Counted spend and cap: the `.capHeadroom` basis (`:244`). The rest is not in the projection. | `minimumAmount`, `reachedTierThreshold` |
| Capped, rest, calm, failed | The action | `action` | Nothing |

There is no cap field: whenever the cap climb draws, `basis.target` already is the cap the server counts against, and a capped card needs no amount.

**The two fields.** Plain numbers for the picture only.

```swift
// Added to RewardRowProjection. Sketch, unverified.
/// The calculation's minimum spend, 0 with none. Picture only.
let minimumAmount: Double
/// The spend threshold of the active spending tier, 0 with none. Picture only.
let reachedTierThreshold: Double
```

`make` builds `minimumAmount` from `calc.minimumSpend`, and `reachedTierThreshold` by looking `calc.activeSpendingTierId` up in `row.card.spendingTiers[].spendThreshold`. Each is 0 when it is missing, not finite or not positive. The base level has no tier id, so a card with no tier reached carries 0. Range rows carry 0 and 0. The web port reads `calculation.minimum_spend` and `calculation.active_spending_tier_id` against `row.card.spendingTiers`; the server already sends both and the types already carry them.

**Guards, in the mapping only.**

- A ratio whose denominator is not positive counts as 1, and a value that is not finite counts as 0.
- For `.nextTier`: if the minimum is not below the threshold (an older report or a test row without it), the climb is measured from 0.
- For `.capHeadroom`: if the cap is not above the foot of the climb (the reached tier, or the minimum), measure from 0.
- A missing basis leaves the foot of the climb: 0, or 0.5 after a tier.

### Channels

| Channel | Source | Rule |
| --- | --- | --- |
| Lit extent | `h` | Gate: lit from the left edge to `x = h × W`, with a falloff of 4% of the width either side of it. Every later stage: the whole band. Dark mode: underexposed to the right. Light mode: gold laid over the blue sky to the left, the ground sunlit to the left and cooled to the right. Calm: an even, softer light. Failed: underexposed everywhere (light mode: an overcast sky). |
| Marker | `h`, gate only | Hairline at `x = h × W` |
| Sun position | `h`, `v` | Gate: on the horizon at `clamp(h, 0.07, 0.85)`, lifting clear over `h` 0.85 to 1. From the minimum on: in the column, from just above the ground (`v` 0) to off the top (`v` 1). None when failed. |
| Brightness | `v` | Light mode: the gold over the sky deepens from 76% to 92%. Dark mode: the bloom grows to 30%. Both: the crest strokes, the horizon warmth and the halo. The pour from the top edge fades in from `v` 0.4 to full at 1. |
| Ridge gap | `h` | `1 − h` of the full gap; apart at rest when failed or without a target |
| Rings | `v` | Four soft rings around the sun, growing from 14% of the width to 38% as `v` goes from 0 to 1 |
| Sun disc | tone | Amber `SunRiseTop` to `SunRiseBottom` while the tone is needs-minimum, `SunDiscTop` to `SunDiscBottom` otherwise |
| Sky | `rewardType`, appearance | Light mode: a daytime blue sky; miles higher, cooler and clearer with a faint contrail, cashback a warmer, softer haze; failed an overcast grey. Dark mode: miles the night print, cashback the dusk print. |
| Monochrome | `tone == .failed` | Saturation 0.15 over the whole face |

### State table: the picture

Examples are the `RewardRowProjectionTests` fixtures in `apps/ios/HowMuchTests/RewardsReportTests.swift`. They use SGD, as of 23 Sep 2026, with a 1 to 30 Sep period unless noted. The test rows set the server's figures in the calculation, including its `minimum_spend`, so the picture values below follow from them. A row that needs the card's tier says so.

| # | State | Trigger in the projection | `h` and marker | Sun and rings | Ridges and light |
| --- | --- | --- | --- | --- | --- |
| 1 | Below minimum | `.minimum`, tone `needsMinimum` | `h` 0.873 (698 of 800); marker at 0.873 W | The sun has arrived at 0.85 and has lifted 15% of the way clear; amber disc; rings at their smallest | Spend line 87% of the way up to the target horizon. Lit to the marker. |
| 2 | Monthly minimum behind | `.monthlyMinimum`, `needsMinimum` | `h` 0.833 (250 of 300); marker at 0.833 W | A half disc on the horizon at 0.833 W, riding the marker | Spend line 83% of the way up |
| 3 | Next tier | `.nextTier`, `earning` | 1, no marker | In the column, `v` 0.42 (1,340 of 1,600, no minimum); rings at 24% of the width | Merged; the whole band lit |
| 4 | Intermediate cap | `.nextTier` with exception `tierCapReached` | As 3. Web R1 marks it complete today; that is a bug. | As 3 | As 3; exception in the slip |
| 5 | Cap headroom | `.capHeadroom`, `earning` | 1 | In the column, `v` 0.3 (650 counted, from the 500 minimum to the 1,000 cap); rings at 21% | Merged; lit |
| 6 | Minimum met | `.minimumMet`, `earning` | 1 | Resting just above the ground in the column; rings at 14% | Merged; lit |
| 7 | Top tier | `.topTier`, `earning`, no basis | 1 | Halfway up the column; rings at 26% | Merged; lit and brighter |
| 8 | Cap reached, not terminal | `.capReached(terminal: false)`, `earning` | 1 | Off the top edge; the rings' lower arcs pour into the frame | Merged; the brightest, with the pour from the top edge. Rare: a next tier exists at or below spend. |
| 9 | Terminal cap | `.capReached(terminal: true)`, `complete` | 1 | As 8 | As 8. Headline in foot ink. |
| 10 | Partial-block cap | As 9, basis 995 of 1,000 | 1. The picture follows the action, the figure stays raw. | As 9 | As 9 |
| 11 | Failed | `.qualificationFailed`, `failed` | 0, no marker | No sun | The brand pair, apart; underexposed everywhere; monochrome. Headline in `FailedInk`. |
| 12 | No target | `.noTarget`, `neutral`, no fill | 1 | Resting in the column; rings at 14% | The brand pair, apart; an even, softer light |
| 13 | Rewards locked or withheld | `.noTarget` with `rewardsLocked` or `minimumNotMet` | As 12 | As 12 | As 12; exception in the slip |
| 14 | Neutral with a target | A target action whose `earning` tone was downgraded to `neutral` | By its action | By its action | By its action; only the ink changes |
| 15 | Range | `.range` | No picture | | Paper row without a print |
| 16 | No as-of date | Any; `deadline` is nil | As its state | As its state | As its state |

State 3's test row has no minimum, so the climb is measured from 0; with an 800 minimum it would be 0.34. State 5's row sets the 500 minimum in the calculation, which gives 0.3; without it the answer would be 0.65.

An urgent deadline is not a picture state. Any `.ends` deadline within 3 days sets the deadline text in SemiBold `UrgentInk` on the ridge (dark umber in light mode, warm gold in dark mode), or the tone ink on paper, exactly as today.

The table holds in both appearances. The geometry, the sun's path, the rings, the ridge gap and the marker never change with the mode; only the colours and the way light is laid on do. Dark mode draws the table on today's prints. Light mode draws it on the daytime faces below.

### State table: light-mode faces

Values are in Colour assets. "Gold" is `SkyLit` laid over the blue at `0.76 + 0.16 × v` to the left of the marker, falling to nothing over the falloff while the minimum journey runs.

| # | State | Sky and light | Sun and rings | Ground and marker | Text |
| --- | --- | --- | --- | --- | --- |
| 1, 2 | Gate | Blue sky, gold from the left edge to the marker, then blue under a cool 15% dim. At `h` 0 only a sliver at the left is gold; at 0.2 a fifth of the width is. | A half disc on the horizon at the marker, with the amber `SunRise` disc, which reads as a sunrise against the blue; small rings | Apart. Light greens, gold-washed to the marker, cooled and dimmed beyond but never dark. The warm white marker with its faint dark edge, on the sky and the ground alike. | Name in dark ink on the gold and the blue alike. Foot in dark ink; `UrgentInk` dark umber when urgent. |
| 3, 4, 5 | Climb | The whole band gold at `0.76 + 0.16 × v`, deepening as the sun climbs; the pour fades in from `v` 0.4 | In the column, climbing; the rings grow and, with the core glow, are screened over the sky, so they read as glare, never as mud on the gold | Merged, gold-washed end to end; no marker | As 1 |
| 6, 7 | Rest | The whole band gold: 0.76 at rest (6), 0.84 at halfway (7) | Resting (6) or halfway (7) in the column | Merged | As 1 |
| 8, 9, 10 | Capped | Gold at 0.92 with the pour at full strength from the top edge over the sun's column: a warm, bright noon | Off the top edge; the rings' lower arcs show at the top | Merged; crest bright end to end | Headline in foot ink |
| 12, 13 | Calm: no target, locked or withheld | Even, no split: gold at a steady 42% across the whole sky, softer than any lit band. Miles keeps its contrail. | Resting in the column; small rings | The brand pair, apart; the ground's gold at a steady 16% | As 1 |
| 11 | Failed | `SkyOvercast`, a pale flat grey, instead of the blue; no gold, no contrail | No sun, no rings | The brand pair, apart and cooled end to end; then the whole face at saturation 0.15; no marker | `FailedInk`, a dark red, on the headline only, where it is today |
| 14 | Neutral with a target | By its action | By its action | By its action | Only the ink changes |
| 15 | Range | No picture | | | Paper row without a print |

**Miles against cashback.** One device, altitude, and only in light mode: miles is a higher, cooler, clearer blue with a faint contrail; cashback is a warmer, softer haze with none. Dark mode already tells them apart by night and dusk.

### State table: words and VoiceOver

Unchanged from version 1. The label is always the card name (`projection.title`), or "Rewards, <name>" in the register, with the hints unchanged. The value is `RewardRowText.accessibilityValue`, unchanged.

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
| 10 | `:1153` spend 996, counted 995, cap 1,000 | Bonus cap reached · Resets in 8 days; $995.00 / $1,000.00 · $0.00 earned | The spoken figure is 995 of 1,000, from the basis, not from the sun's height |
| 11 | `:1199` July 200 of 300 failed; period 1 Jul to 30 Sep | July minimum missed · Resets in 8 days; $0.00 spent · $0.00 earned | July minimum missed. $0.00 spent · $0.00 earned. Resets in 8 days, period ends 30 Sep. $0.00 earned |
| 12 | `:1163` spend 420, earned 8.40 | No cap · Resets in 8 days; $420.00 spent · $8.40 earned | No cap. $420.00 spent · $8.40 earned. Resets in 8 days, period ends 30 Sep. $8.40 earned |
| 13 | `:1246` September met, October pending; period 1 Sep to 31 Oct; spend 900 | No cap · Resets in 39 days; $900.00 spent · $0.00 earned; slip "Rewards unlock after 31 Oct" | No cap. $900.00 spent · $0.00 earned. Resets in 39 days, period ends 31 Oct. $0.00 earned. Rewards unlock after 31 Oct |
| 14 | No dedicated test | The target's headline, plus "Rewards unlock after …" or "Minimum not yet met" | As the text |
| 15 | `:1365` spend 1,000, earned 40 | **$40.00** earned; $1,000.00 spent | $40.00 earned. $1,000.00 spent |
| 16 | `:1357` no as-of date | As its state, with no deadline | As its state, without the deadline clause |

### Capped is done

Version 1 set the sun behind the ridge at a terminal cap and dimmed the sky. Version 2 reversed that into the brightest state. Version 3 keeps it the brightest and finishes the climb the owner described:

- At the cap the sun has climbed off the top edge. The sky is at its brightest: the gold at its deepest in light mode (the full bloom in dark mode), the crest strokes at 100%, and the pour at full strength from the top edge over the sun's column. There is no dim overlay and no afterglow.
- Capped still reads as done, not failed. The band is bright and still, the headline says "Bonus cap reached", and the iOS `.complete` ink moves from red to dusk. Failed keeps the opposite look: overcast, monochrome, no sun, red headline.
- A terminal cap, a non-terminal cap and a card beyond its cap look the same. Only the words differ ("$150.00 beyond cap").

### The partial-block cap

The server sets `maximum_spend_exceeded` once the headroom is less than one earning block. So a card can be "Bonus cap reached" at $995.00 of $1,000.00 (state 10). The decision:

- The picture follows the **action**: capped, `v` 1, the sun off the top edge, because the server says the bonus is spent and the projection pins `fill` to 1.
- The figure stays **raw**: "$995.00 / $1,000.00". It is never rounded up to look full.
- The sheet's existing Cap target row already carries the block caption: "Counts spend in whole earning blocks, so the room left can differ by up to one block." Nothing new is added to the board row. Whether to add a row hint is open question 7.

### The Featured mark

The "✦" after "DBS · MILES" on the web face and in the lab is the Featured flag. The owner did not recognise it. Decision: **drop it from the compact row and show the word only in the expanded form.**

- The board opens on **Featured only** whenever any card is featured (`Views/RewardsView.swift:130`), so on the default view a per-row mark would sit on every row and say nothing. The Featured control above the list already names the filter.
- The compact strip has no caps line, so a pill would cost a line, about 13pt per row.
- Where a caps line already exists, "Featured" is a plain word in it: "DBS · Miles · Featured". That is the iOS sheet slip and the web's desktop 3:2 face. No glyph, no pill.

## Geometry

### Layouts

| Layout | Used for | Size at the default text size (`.large`) |
| --- | --- | --- |
| **Strip** | Rewards board rows | Full row width, about 114pt tall since the phone cut (104pt before it). The row is the frame. |
| **Paper row with print** | Account register strip | About 96pt, with a 90 × 60pt print on the trailing side |
| **Paper row with band** | Board and register rows at accessibility text sizes | A 64pt scene band above the text |
| **Paper row, plain** | Range Report "Cards" section | As today, no picture |
| **Hero** | Detail sheet header | A 3:2 print with a 6pt border |

### The scene

Every layout draws the same scene, back to front:

1. sky, horizon warmth; in light mode the contrail (miles) and then the sky's gold wash; in dark mode the bloom; then, from `v` 0.4, the pour from the top edge;
2. halo: the four rings and the core glow;
3. upper ridge (target horizon) with its crest stroke;
4. lower ridge (spend horizon) with its crest stroke, or one merged crest;
5. light mode: the ground's gold wash, clipped to the ridges; dark mode: the foot scrim (strip only);
6. the veil (the underexposure right of the marker, in the minimum journey only);
7. the sun disc, clipped to the sky, so it sits behind the target horizon until it climbs clear, and is never veiled;
8. the marker (minimum journey only).

Text is never inside the scene. Each layout sets:

| Layout | Sun's column `X` | Target horizon `U(x)` | Spend floor `Fl(x)` | `r` |
| --- | --- | --- | --- | --- |
| Strip | 0.85 W | Brand back rise: `N + 14pt` at the left to `N + 2pt` at the right | `U(x)` + (`F − 3pt` − (`N + 14pt`)): the same shape, 3pt above the foot at the left | 10pt |
| Print, 90 × 60 | 0.85 W | Brand back ridge | 0.82 h, ±0.01 h | 4pt |
| Band, 64pt | 0.85 W | Brand back rise: 0.56 h to 0.42 h | `U(x)` + 0.26 h | 7pt |
| Hero | 0.85 W | Brand back ridge: 0.665 h at the left, 0.42 h at the right | 0.80 h, ±0.01 h | 0.045 W |
| Web face, desktop 3:2 | As Hero | As Hero | As Hero | 4.5% of the width (shipped) |
| Web strip, phones | As Strip | | | |

`N` is the bottom of the name's line box and `F` the top of the headline, both measured in the row. So long names and large text move the ridges rather than overlap them.

**The phone cut (10 Oct 2026).** The strip and the band are a different picture from the hero, not a smaller one: a 104pt row has no room for the whole landscape, and the owner found the first cut's sun a bead on a line with clipped rings and stray hairlines. The phone layouts therefore draw the same scene with four changes, and the hero and the web's 3:2 face keep the full treatment:

- **The sun is the marker.** No hairline. The disc rides at the fill (0.07 to 0.85 W) and the lit edge and the ridge gap carry the exact point. A hairline from the sky through the foot text read as a scratch, and beside the column it read as a pole the sun was skewered on.
- **A half-sun on the horizon.** The disc is 10pt (7pt on the band) and its centre sits exactly on the target horizon while it rides, so the sky clip leaves a clean semicircle. It lifts clear from there, as before. Under the name the horizon is at least 12pt below it, so the half-sun's top stays clear of the name's line box.
- **The icon's two slopes.** The owner asked for the app icon's pair of rising ridges. The strip's horizons are no longer level: the target horizon takes the brand back ridge's rise (`BACK_RISE`, the shipped path normalised to 0 at its highest, right, and 1 at its lowest, left), 12pt deep, from 14pt under the name at the left to 2pt under it at the right, where the sun's column is. The spend floor is the same shape, as far down as the words allow: 3pt above the foot at its lowest point, the left edge. The lower slope is anchored there and only its far end rises (later on 10 Oct 2026, after the owner's pins): in the minimum journey it is `Fl − (Fl − U) × h × x/W`, so at `h` 0 the pair is equidistant and at the right edge the gap is `(1 − h)` of the floor's; once the minimum is met it is `Fl − (Fl − U) × min(1, x/(m W))`, where `m` is the day of the period the minimum was met as a share of its days (`minimum_met_on` from the API, 1 when unknown), so the two slopes meet at that day and run as one from there. Where they meet is when the minimum was reached. A card with no minimum keeps the pair apart: the convergence is the minimum's own read, and the climb is the sun's. The sky band is 34pt; the row is about 114pt.
- **An amber dusk print.** In dark mode the cashback sky is a deep amber (`SkyCashback1` #7A4420 to #5A3016 to #3F2211), not the former pale cream that sat like a lit window in the dark chrome; its name ink goes light (`InkCashback` #F7F5EF in dark), its marker takes the night print's gold (`MarkerCashback` #FFD98C at 35%), its veil cast stays #D4CBD4, the pour peaks at 0.45 and the halo adds light with the screen blend like every other face. The prints' sun is a gold going to orange (`SunDiscTop` #FFD27A to `SunDiscBottom` #E8923A, the rise disc #F7B35C to #C4651C, rim #8A4A18, core #F0B35A): lighter than its sky, never glaring on it. The daytime faces keep the near-white disc.
- **The lit edge, each side moved towards the other.** The daytime skies are version 3's blues again (cashback #8DB6D8 to #EBE6DD, miles #6EA6DA to #DCEBF6), the gold its version 3 peaks and the dim its cool #3D5674 at 15%, after two tries at softening them (a grey-blue sky, then the prints' shade) that the owner found either still too contrasty or too drastic a changeover. Instead each side of the edge is moved towards the other as a colour, by a tenth on the sky and a fifth on the ground (`MEET` in the scene, `ExposureScene.meet` on iOS): the lit side keeps 0.9 (0.8) of its gold and takes 0.1 (0.2) of the dim, the unlit side keeps 0.9 (0.8) of the dim and takes 0.1 (0.2) of the gold. The edge stays a clean vertical step; it is just a smaller one.
- **One soft glow, no rings.** The halo is one radial falloff in the rings' palette (Ring1 at the centre, Ring2 at 30%, Ring3 at 60%, Ring4 at 82%, clear at the edge) over the core glow, with the rings' radius `R` and opacity. Posterised rings clipped by a short frame's top edge and by the ridges read as concentric arcs; a falloff clipped the same way still reads as light.
- **No unlit sliver.** As the sun lifts (`h` 0.85 to 1) the veil's peak falls by `lift` and the gold beyond the lit edge rises by `lift`, so the last of the band lights with the lift instead of leaving a 4% strip of dusk at the card's edge.

The lab's 12pt disc was the right instinct; 10pt fits the 28pt band without growing the row more than 4pt.

**Brand ridge.** Use the web SVG paths verbatim (`apps/web/src/pages/Rewards.tsx:697-702`, viewBox `0 400 1024 624`, stretched into the bottom 58% of the frame). A SwiftUI `Path` cannot be asked for y at a given x, so sample the back crest once into a static 65-point table and interpolate. The web port uses the same table. "The brand pair" is the back and front ridges as the web ships them, which is what a card without a journey (failed, no target) draws.

**The brand ridge everywhere (10 Oct 2026).** Version 3 gave the strip and the band level horizons. The phone cut replaced them with the icon's two slopes (see above), so on every layout the sun follows the ridge's slope as it rides; it is still sitting on the horizon, not rising above it. The phone's slope is gentle (12pt across the width), so its minimum journey is nearly horizontal and the climb keeps most of the frame.

### The sun's path

- **Across.** `sunX(h) = clamp(h, 0.07, 0.85) × W` while `h` is below 1, and `0.85 × W` from then on. The marker is at exactly `h × W`, so the sun rides it from 0.07 to 0.85 and waits at 0.07 before that. The disc never clips at the left.
- **On the horizon** (`h` up to 0.85): the disc's centre a hair below the target horizon, `y = U(X) + 0.08 r`, so a half disc peeks over the ground line. On the strip and the band the centre is exactly on the horizon (`seat` 0), a clean half-sun. It does not rise during this part of the minimum journey.
- **Lifting** (`h` from 0.85 to 1): `y` runs from the horizon position to the resting position as `lift` goes from 0 to 1, while the last of the band fills.
- **Resting** (`h` 1, `v` 0): the disc's bottom 0.15 `r` above the merged ridge, `y = U(X) − 1.15 r`.
- **Climbing:** `y = lerp(U(X) − 1.15 r, −1.05 r, v)`. At `v` 1 the disc's bottom is 0.05 `r` above the top edge: fully off screen. The halo and the rings stay centred on it, so their lower arcs pour down into the frame.
- **Failed:** no sun.

The y axis points down. On the strip at `.large`, with `N` about 32pt, `U` at the column is about 34.6pt (the back rise is 0.05 there), so the 10pt sun sits at 34.6pt, rests with its centre about 23pt from the top, is halfway at about 6pt and leaves at −10.5pt: a 34pt climb. On the hero (349 × 233pt), the target horizon is about 105pt down at the column, so the sun rests at about 87pt, is halfway at about 35pt (0.15 h) and leaves at −16.5pt. While the sun is on the horizon under the name column, its top sits at least 2pt below the name's line box, which is why the strip's target horizon is never less than 12pt below the name.

**Why the column is at 0.85.** It has to clear everything at the top right and the bottom right without crowding the right edge.

- **The chevron.** The web strip and the lab put a chevron 12pt from the right edge at the top; iOS drops it today (open question 4), but the column should not have to move if it comes back. The disc at 0.85 W spans about 0.81 to 0.89 W on the hero and less on the strip, which clears a chevron at 0.95 W.
- **The earned figure and the deadline.** The web face sets the earned figure 14pt from the right at the bottom, and every layout sets the deadline at the trailing end of the headline line. Both sit below the ground line, so the resting disc, whose bottom is above the target horizon, never covers them.
- **The journey's end.** The sun rides the marker up to 0.85 and then lifts, so at the end of the minimum journey it is already in its column and meeting the minimum only finishes the lift.
- **The name.** Ring 4 at its widest (`v` 1) reaches 0.35 W either side of the column, so its faint outer edge (7%) ends near 0.50 W, the end of the name column. On the strip and the band the rings are also capped by the frame's height, so they stay well clear. No ring ever sits behind the name at more than its faintest.

### The light

The art is lit from the left edge to the marker and underexposed to its right while the minimum journey runs. This is the primary read of that journey; from the minimum on, the whole band is lit and the sun's height is the read.

- **Veil strength.** `veil(x) = smoothstep(h − 0.04, h + 0.04, x / W)`. Full light left of the marker, a soft falloff of 4% of the width either side of it, full veil beyond. Once `h` is 1 the whole band is lit and nothing is veiled. The sun disc is drawn above the veil, so it is never dimmed.
- **Dark mode: dim and desaturate.** A dusk cast taken from the brand's rose-mauve:
  - one full-frame fill with blend mode `.saturation`, colour `VeilGrey` #808080 at alpha 0.5 × `veil` (half way to grey);
  - one full-frame fill with blend mode `.multiply`, from white to `VeilCashback` #D4CBD4 on the dusk print or `VeilMiles` #8A8496 on the night print, by `veil`.
- **Light mode: gold over blue, on light ground.** The same `veil(x)` lays light on the lit side and a cool dim on the other, so progress reads as a change of hue (gold against blue) as well as of brightness. Since 10 Oct 2026 each side carries a share of the other (a tenth on the sky, a fifth on the ground), so with `m` that share:
  - the sky is the daytime blue, and the unlit sky stays that blue under the dim;
  - straight after the sky, one full-frame fill of `SkyLit` #FFD98C at alpha `(0.76 + 0.16 × v) × 0.9 × (1 − (1 − m) × veil)`, `m` 0.1: full on the lit side, a tenth of that beyond (more as the strip's sun lifts). The ridges are drawn over it, so it only shows on the sky;
  - after the ridges, a second `SkyLit` fill at `(0.24 + 0.12 × v) × 0.8 × (1 − (1 − m) × veil)`, `m` 0.2, clipped to the ridges, so the ground is sunlit to the marker and a fifth as much beyond it;
  - after those, one full-frame fill of `VeilDim` #3D5674 at alpha 0.15 × (m + (1 − m) × `veil`) with `m` 0.1 (14% when failed): the unlit side cools and dims a little, and the lit side takes a tenth of that, but it never darkens enough to break a floor.
- **Veil limits.** The dusk veil is deliberately gentle: it is capped so `InkCashback` keeps 6.6:1 on the darkest veiled dusk stop, because a long name can sit on the dim side. The night veil can be darker: it only raises contrast for light inks. In light mode the dim is 15% at most, which leaves dark ink at 5.8:1 or more on the dimmed sky and `UrgentInk` at 4.7:1 on the dimmed ground; the shares moved across the edge only lower contrast between the two sides, never against the ink.
- **Brightness grows with the climb.** Light mode: the gold deepens from 76% to 92% over the sky and from 24% to 36% over the ground. Dark mode: `Bloom` #FFE3AC at 30% × `v` over the sky (screen blend on the night print), and the horizon warmth × `(1 + 0.5 × v)`. Both: the crest strokes from 90% to 100% and the halo from 40% to 100%. At rest the band is lit but plain; at the cap it is at its brightest.
- **The pour.** From `v` 0.4 a radial gradient centred on the sun's column at the top edge, from `SunDiscTop` at the centre through `SunCore` at 30% of the radius to nothing at the radius: the glow pouring down from a sun that has left the frame. Its alpha is `peak × clamp((v − 0.4) / 0.6)`, drawn over the sky only. Peak is 0.65 in light mode, 0.55 on the dusk print and 0.65 on the night print. Radius is 0.62 W on the strip, print and band and 0.78 W on the hero, except on the night print, where it is 0.35 W on every layout: the lab's wider pour takes `InkMiles` to 2.6:1 at the end of the name over the bloom, and 0.35 W keeps it at 5.0:1 or more. Light ink on the night print is the only pair that a pour can break; dark ink only gains.
- **Calm:** no veil, no bloom and no pour, an even, softer light. In light mode, `SkyLit` at a steady 30% across the sky and 12% on the ground. **Failed:** `veil` 1 everywhere, plus the face's saturation 0.15. In light mode the sky is `SkyOvercast`, gets no gold, and the dim is 14% everywhere.
- **Cost.** Two gradient fills for the veil, one bloom or gold fill and one pour fill in the same Canvas pass; light mode adds the second gold wash and a clip to the ridge path. No offscreen layer, no blur, no second draw of the scene. Blend modes act on what the context has already drawn. The lit washes fade to `SkyLit` at zero alpha, never to `.clear`, so the falloff does not pass through grey.
- **Differentiate Without Colour.** In dark mode the veil darkens as well as desaturates, so the lit edge reads in luminance alone. In light mode the edge is first a hue step; on the sky it is also a luminance step of 1.3 to 2.1:1, on the ground a smaller one (1.3:1), and the marker carries the exact point. In the climb the read is the sun's position, which needs no colour.

### The progress marker

- **Where.** The hero and the web's 3:2 face only. The strip and the band draw no hairline (see The phone cut): there the sun rides at the fill and is the marker.
- **Position.** `x = h × W`, exactly. Drawn in the minimum journey only. It goes with the minimum, and never shows in any other stage.
- **Extent.** From 0.06 h to the bottom edge. It breaks across the visible half of the sun's disc, 3 units clear of the rim on a 1,000-wide scene (about 1pt on the strip), as in the brand mark (`assets/icon/halation-light.svg`), where the scrub line passes behind the sun.
- **Tones by appearance.**
  - Dark mode: two tones split at the target horizon, as in the brand mark. On the sky, `MarkerCashback` and `MarkerMiles`, both #FFD98C at 35%, on the dusk and the night print. On the ridges, `MarkerRidge`, pale #F7F5EF at 20%.
  - Light mode: one warm white line, #FFF8E6 at 85%, on the sky and the ground alike, over a faint dark edge (`MarkerEdge`, #1C1B18 at 12%, one device pixel either side of the line). The edge gives the line its definition on the gold and the pale sky. The owner approved warm white; the umber and dark-ridge markers proposed for light mode are withdrawn.
- **Crisp.** Two device pixels wide (1pt at 2x, 0.67pt at 3x), with its x snapped to the device pixel grid through `displayScale`, so it never smears across three pixels.
- **Faint but findable.** Dark mode: about 2:1 against the dusk sky, 2.7:1 against the night sky and 1.55 to 1.75:1 on the ridges. Light mode: the warm white is faint by design, 1.1 to 1.3:1 on the pale sky and the gold, up to 2.5:1 on the saturated blue, 1.6 to 2.0:1 on the front ridge and 1.4 to 1.7:1 on the back ridge, with the dark edge adding a 1.25:1 shadow either side. That is below the 3:1 WCAG 1.4.11 asks of a graphic needed to understand content. It is acceptable because the marker is decorative and non-text: the figures, the lit edge, the ridge gap and the sun carry the same read, and nothing depends on the line alone.
- **Under text.** It is drawn last in the scene, after the veil, so it stays visible on the dim side. Text sits above it. At a small `h` it passes behind the name and the foot text. Where a glyph meets it, the ink keeps at least 4.6:1 against the marker pixel in dark mode, and 9.6:1 in light mode, where a dark glyph meets a near-white line. That is why the warm white works now: version 2 ruled it out because it dropped light foot ink to about 1.2:1, and light mode no longer sets light ink on the ground. The OCR snapshot and state N in the fixture prove legibility.

### The ridge pair

The upper line is the **target horizon**, in the brand's ridgeline shape (a gentle 12pt rise on the strip and the band). The lower line is the **spend horizon**: stylised, the brand front ridge's rise on the phone and nearly level on the face, spanning the full width, so it never ends abruptly. The band of `RidgeBack` showing between them is what is left to the minimum.

#### Level (specified)

- Upper line: `U(x)`. Fill `RidgeBack`. Crest stroke `TargetCrest`: `Crest` at 40%, 1pt.
- Lower line, hero and web face: `Fl(x) + h × (U(x) − Fl(x))`. Strip and band: anchored at the floor at the left edge, `Fl − (Fl − U) × h × x/W` in the journey and `Fl − (Fl − U) × min(1, x/(m W))` once met, `m` the met day's share of the period (see the phone cut). `h` is the fill in the minimum journey, 1 in every later stage, and a failed card or one without a target draws the brand pair apart at rest. Fill `RidgeFront` to the bottom. Crest stroke `SpendCrest`: `Crest` at 75%, 1.5pt.
- On the hero and the web face the lower line is a blend of the level floor and the target horizon, so it lifts towards the upper line everywhere at once and cannot cross it. At `h` 0 it is level; as it rises it takes on the horizon's shape; at `h` 1 the two coincide. On the phone it pivots from its left anchor instead, and the meeting point is a date.
- **Merged:** one crest stroke at 90%, brightening to 100% with `v`. From there the merged ridge stays put. It does not lift with the climb: the sun carries that read, and a second encoding would compete with it.
- On the hero and the web face the gap at any x is `(1 − h) × (Fl(x) − U(x))`. On the strip the floor is the horizon's own shape (about 17pt below it at `.large`) and the gap narrows from the left edge towards the right: `(1 − h x/W)` of the floor's in the journey, closed from the met day on once met.
- The veil greys and cools the crest strokes right of the marker, so the lit part of the spend crest glows and the rest reads cold.

#### Literal (alternative)

The owner may have meant the Spend Ridge's drawn line: cumulative spend by day from the period's start to today, which then, instead of ending, "goes horizontal" to the right edge.

- Lower line from x = 0 to today's x: `Fl(x) + min(1, cumulative(day) / minimum) × (U(x) − Fl(x))`, monotone cubic, no overshoot.
- From today's x to the right edge: today's level, drawn with the level formula so the "horizontal" run cannot cross the upper line.
- After the minimum, merged from the crossing day on, and still from there.

#### Recommendation: level

- **One meaning per axis.** The literal line's x is days, while the minimum journey's x is progress. Two meanings on one axis is exactly what the owner's first point removed.
- **Data.** The report carries no daily series. A literal line needs `periods[].daily` (date and cumulative qualifying spend) from the Worker. The phone's own transactions cannot reproduce exclusions, refunds, block rounding or category caps.
- **Honesty.** The level line's height comes from the same `fill` as the figure.

The literal reading is phase two at most, and then only in the sheet's hero. In code the scene takes a `RidgeStyle` with `.level` only, so `.literal(series:)` can be added later without touching anything else. The app ships no user-facing toggle. The lab page carries a Level/Literal toggle on its live card, with a clearly labelled synthetic series, so the owner can compare the two.

### Rings

- On the hero and the web face: always four soft rings around the sun, plus a core glow, whenever there is a sun. The strip and the band draw one smooth glow in the same palette instead (see The phone cut). They grow continuously with `v`: with `R = (0.14 + 0.24 × v) × W`, ring k is a filled disc centred on the sun with radius `R` times 0.27, 0.46, 0.68 and 0.92 for rings 1 to 4, inner to outer, and the core glow is 0.15 `R`. On the strip and the band, `R` is also capped at `(0.42 + 0.6 × v) × H`, so the rings stay inside the frame's height. The discs are stacked, largest first, so each step reads as posterised light, not a drawn line.
- Colours: `Ring1` to `Ring4`, inner to outer. On every face, draw the rings and the core glow with the screen blend mode, as web does, so they add light: warm rather than olive on the prints, glare rather than mud on the gold. (The dusk print kept the normal blend while it was a pale cream; it is amber since 10 Oct 2026.)
- Halo opacity: `0.4 + 0.6 × v`. The core glow under the disc always draws when there is a sun.
- At rest the outer ring reaches 0.13 W either side of the column, and at the cap 0.35 W. At the cap the sun is off screen, so only the rings' lower arcs show.
- The rings are art behind text: ring 3 and ring 4 are at 14% and 7% alpha, and the contrast tables cover them.

### Strip, default text size

In the minimum journey (card A, `h` 0.63):

```
 W = 361pt (iPhone 16 with 16pt list insets), corner radius 16 (Theme.Radius.card)
┌──────────────────────────────────────────────────────────────┐  top padding 9
│ Exposure Below                        ┊░░░░░░░░░░░░░░░░░░░░░░│  name, line ~23pt, at most 0.50 W; the sky is lit up to the marker
│                                       ┊░░░░░░░░░░░░░░░░░░░░░░│
│‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾(◒)‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾│  target horizon, the icon's back slope, 14pt to 2pt under the name; the half-sun rides at the fill (no hairline)
│                                       ┊   gap: what is left  │
│‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾┊‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾│  spend horizon, lifted 63% of the way up to the target
│ $184.50 to minimum                    ┊         8 days left  │  headline line ~22pt
│ $315.50 / $500.00 · $0.00 earned                             │  2, basis line ~15, bottom 9
└──────────────────────────────────────────────────────────────┘  about 114pt
      lit ◄────────────────────┤ lit edge at x = h × W, h = 0.63 ├────► underexposed (░)
```

Past the minimum (card P, climbing after its tier):

```
┌──────────────────────────────────────────────────────────────┐
│ Exposure Journey                                             │  name, line ~23pt; the whole band is lit and there is no marker
│                                        ·  (◉)  ·             │  v = 0.69: the sun is high in its column, ringed and haloed
│                                                              │
│‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾│  one merged ridge, the icon's back slope, 14pt to 2pt under the name
│                                                              │
│ $184.50 left before bonus cap                   8 days left  │  headline line ~22pt
│ $315.50 / $500.00 · $0.00 earned                             │  basis line
└──────────────────────────────────────────────────────────────┘
   The sun climbs straight up the column at 0.85 W: resting (v 0), halfway (0.5), off the top edge (1).
```

Height budget at `.large`: top padding 9, name 23, sky band 34 (the two slopes: the target horizon 14pt to 2pt under the name, the spend floor the same shape 17pt below it, 3pt above the headline at the left), headline 22, 2, basis 15, bottom 9. That is about 114pt, 10pt more than the first cut, so about 5 rows still fit on an iPhone 16.

| Element | Type | Ink |
| --- | --- | --- |
| Account emoji and name | Instrument Serif Italic 19pt, relative to `.title3`; at most 2 lines, then a tail truncation; at most 0.50 W | `InkCashback` or `InkMiles`, which resolve by appearance: dark on every light-mode sky, light on both prints |
| Amount | IBM Plex Mono SemiBold 17pt, relative to `.headline` | `FootInk`, or `FailedInk` for a failed card |
| Action label | IBM Plex Sans 15pt, relative to `.subheadline` | `FootInk` |
| Deadline, trailing | IBM Plex Sans 13pt, relative to `.footnote`; SemiBold when urgent | `FootInkSoft`; `UrgentInk` when urgent |
| Basis line | IBM Plex Mono 12pt, relative to `.caption1`; may wrap | `FootInkSoft` |

The foot inks resolve by appearance: dark in light mode, on the light ground; light in dark mode, on the dark ground.

- The headline line keeps today's `ViewThatFits` behaviour (`RewardsView.swift:920-958`): if the action and the deadline do not fit on one line, the deadline drops below. The action never wraps mid-phrase.
- Padding is `@ScaledMetric(relativeTo: .body)`: 16 horizontal, 9 vertical.
- **Foot scrim, dark mode only.** A `RidgeFront` gradient at 55% runs under the foot text block, from its top edge down. The foot always sits on the spend ridge, so the scrim is a guard: no layout or text size can put light ink on a light pour or bloom. Light mode draws none: its foot ink is dark, and dark ink clears 4.5:1 on the light ground, the gold, the desaturated side and every sky alike, so there is nothing to guard against.
- **Exceptions** go on a paper slip tucked under the frame, as on the web. The slip is 8pt narrower on each side, starts 10pt under the frame's bottom edge, uses `Theme.card` and has 12pt bottom corners. Lines are IBM Plex Sans Medium 13pt with today's triangle icon and inks (`RewardsView.swift:885-897`): at most 2, then "+N more". Each line adds about 20pt. The frame's height never changes for exceptions.
- The strip leaves out the chevron that today's title line has, and does not take the web face's issuer and type caps line or a Featured mark. See The Featured mark and open question 4. The sun's column leaves room for the chevron if it comes back.

### Paper row with print (register)

- `Theme.card`, radius 16, 14pt vertical and 16pt horizontal padding.
- Leading column: today's four-line content, with the strip's fonts but today's inks on paper (`Theme.textPrimary`, `Theme.rowSecondary`, the tone inks).
- Trailing: a 90 × 60pt print, radius 8 (`Theme.Radius.inset`), with a 0.5pt hairline at `Color.primary` 12%, top-aligned with the name. The gap to the text is 12pt. The print draws the whole scene, marker included; its falloff is about 3.6pt either side of the marker and its climb about 26pt.
- The headline line is narrower here (about 227pt at W 361), so the deadline usually sits below the action.

### Hero (detail sheet)

```
┌── 6pt border in Theme.card, 0.5pt hairline ────────────────────┐
│ $500.00 minimum                       ┊░░░░░░░░░░░░░░░░░░░░░░│  label, top leading; the marker runs from 0.06 h
│                                       ┊░░░░░░░░░░░░░░░░░░░░░░│
│                                       ┊░░░░░░░░░░░░░░░░░░░░░░│
│                                       ┊░░░░░░░░░░__/‾‾‾‾‾‾‾‾‾│  target horizon: the brand back ridge, rising to the right
│                    ____/‾‾‾‾‾‾‾‾‾‾‾‾‾(◒)‾‾‾‾‾‾‾/             │  the sun rides the marker, half above the horizon
│___________________/                   ┊            ╵         │  ╵ tick: where the sun will rest (x = 0.85 W)
│      gap: left to the minimum         ┊                      │
│~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~┊~~~~~~~~~~~~~~~~~~~~~~│  spend horizon, lifted 63% of the way up to the target
│                                       ┊                      │
└──────────────────────────────────────────────────────────────┘
  1 Sep ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━│━━━━━━━━━ 30 Sep   optional period track, below the art
```

- **Size.** The width is the sheet's content width, capped at 520pt on iPad. Inside a 6pt border the image is `(W − 12) × (W − 12) × 2/3`: 349 × 233pt on an iPhone 16. Outer radius 16, inner radius 10. The 3:2 ratio and the visible border make it read as a photographic print, not a payment card.
- **The scene** is the full version of the strip's: brand back ridge as the target horizon, a level front ridge at 0.80 h as the spend floor, the sun's column, the light and the marker. No pace line, no day ticks.
- **Target label.** One label, top leading, IBM Plex Mono 11pt: the basis target and kind ("$500.00 minimum", "$400.00 monthly minimum", "$1,600.00 next tier", "$1,000.00 bonus cap"). Only in the minimum journey and the climb.
- **Minimum tick.** In the minimum journey, a 4pt tick on the target horizon at the sun's column `X`: where the sun will rest. `TargetCrest` at 60%.
- **Period track (optional).** Time may appear in the sheet only as a separate thin track **below** the art, never inside it: a 2pt rule from the window's start to its end, the elapsed part in `Theme.rowSecondary`, the rest at 30%, a 6pt as-of tick, and both dates at the ends in IBM Plex Mono 10pt. The window is the active month for a monthly minimum, otherwise the period containing the as-of day. The sheet computes it from the row's `periods` and `monthlyQualifications`, which it already has; the projection does not change for it. It is hidden from VoiceOver because the deadline clause already says it. It stays off until the owner answers open question 3.
- **The slip.** Below the hero, in the same clear section, on the grouped background:
  - a caps line (issuer · type, plus "Featured" when the card is featured), in IBM Plex Sans SemiBold 11pt tracked 0.14em, `Theme.rowSecondary`;
  - then today's headline line, the basis line and the exceptions.
- The name stays in the navigation title.
- The in-frame label and tick are fixed-size art annotations that repeat the slip. They are hidden from VoiceOver, and hidden altogether at accessibility text sizes.

### What collapses when

| Text size | Board | Register | Sheet |
| --- | --- | --- | --- |
| xSmall to xxxLarge | Strip. Above `.large` the name wraps to 2 lines, the deadline drops below the action, and the basis line wraps. The sky and the foot grow with the text, and the ridges follow the measured `N` and `F`; the art never scales text. | Paper row with print | Hero and slip |
| AX1 to AX5 | Paper row with band: a full-width 64pt scene band (radius 16 on the top corners), with the text below on paper, full width | Paper row with band | Hero without the in-frame label; the slip text scales |

Estimates: the strip is about 114pt at `.large` and 140 to 160pt at xxxLarge; the band row is about 280pt at AX1 with a two-line name. **Widths:** iPhone SE (3rd generation) gives W 343, iPhone 16 gives 361 and Pro Max gives 398. On iPad the row content is capped at 640pt and centred, because the board has no readable-width limit today and a 700pt-wide strip turns into a thin ribbon.

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
| `RewardRowProjection` fields | `Support/RewardRowProjection.swift:125-139`, built in `make` (`:153-179`) | Gains `minimumAmount` and `reachedTierThreshold` (see Picture data) |
| List-wide arrival animation | `Views/RewardsView.swift:186` | `reduceMotion ? nil : Theme.Motion.arrive` |
| Snapshot row | `apps/ios/HowMuchTests/RewardsReportTests.swift:1485` | Renders the new row; see Verification |

New files: `Support/RewardExposure.swift` (the mapping and the scene geometry), `Views/RewardExposureFace.swift` (the Canvas), `Views/RewardExposureRows.swift` (strip, paper row, hero), `Support/RewardTypography.swift` and `Fonts/`. The project lists files explicitly (`objectVersion = 56`), so add each one to `HowMuch.xcodeproj` and to the HowMuch target.

### Projection additions

Version 2 had none. Version 3 adds the two plain numbers described in Picture data, built in `make` beside the other fields and passed through `build` for every action. The mapping reads `action`, `fill`, `basis`, `minimumAmount`, `reachedTierThreshold`, `deadline?.end` and `rewardType`. Nothing printed or spoken reads the new fields, so `RewardRowText` and the pinned VoiceOver value do not change. The projection's synthesised `Equatable` picks them up, so a change to the calculation's minimum or active tier redraws the face. No code builds a projection with the memberwise initialiser, so nothing else changes. Version 1's `window` and `elapsed` stay dropped.

### The mapping: `RewardExposure`

The mapping lives in one place: `RewardExposure.init?(_:)`, a pure function of a `RewardRowProjection`. It is the mapping table in code. The web port mirrors it as `exposure(projection)`. Its isolated tests are written first; see Verification.

```swift
// Sketch, unverified (no Xcode here).
struct RewardExposure: Equatable {
  enum Stage: Equatable { case gate, climb, rest, capped, calm, failed }
  enum Light: Equatable { case journey, even, overcast }

  /// The animated picture values, each 0...1.
  struct Pose: Equatable {
    var h: Double   // across: the fill of the minimum journey; 1 once it is met or when there is none
    var v: Double   // up: 0 resting just above the ground, 0.5 halfway, 1 off the top edge
    func falls(from old: Pose) -> Bool { h < old.h || v < old.v }
  }

  static let column = 0.85          // where the sun rests, as a share of the width
  static let ride = 0.07...0.85     // where the sun can ride the marker

  var stage: Stage
  var pose: Pose
  var miles: Bool
  /// Whether the card ever had a minimum journey: where a first showing starts.
  var hasMinimum: Bool
  /// Changes when the target does: another action kind, basis target or deadline end.
  var target: String

  var light: Light { stage == .failed ? .overcast : stage == .calm ? .even : .journey }
  var hasMarker: Bool { stage == .gate }
  var hasSun: Bool { stage != .failed }
  /// The marker's x as a share of the width: exactly the fill, in the minimum journey only.
  var markerX: Double? { stage == .gate ? pose.h : nil }
  /// The brand pair, apart at rest: no journey to show.
  var ridgesApart: Bool { stage == .failed || stage == .calm }

  /// Where a first showing starts: a card with a minimum sweeps across and then rises.
  var journeyStart: Pose {
    switch stage {
    case .gate: Pose(h: 0, v: 0)
    case .climb, .rest, .capped: Pose(h: hasMinimum ? 0 : 1, v: 0)
    case .calm, .failed: pose
    }
  }

  /// Nil for range rows, which draw no picture.
  init?(_ p: RewardRowProjection) {
    let minimum = Self.amount(p.minimumAmount), tier = Self.amount(p.reachedTierThreshold)
    switch p.action {
    case .range:
      return nil
    case .qualificationFailed:
      stage = .failed; pose = Pose(h: 0, v: 0)
    case .monthlyMinimum, .minimum:
      stage = .gate; pose = Pose(h: Self.clamp(p.fill ?? 0), v: 0)
    case .nextTier:
      stage = .climb
      // Once a tier is reached the sun stays at halfway: it never sinks towards a further tier.
      var v = tier > 0 ? 0.5 : 0
      if tier == 0, let spend = p.basis?.spend, let next = p.basis?.target {
        let from = minimum < next ? minimum : 0
        v = 0.5 * Self.ratio(spend - from, next - from)
      }
      pose = Pose(h: 1, v: v)
    case .capHeadroom:
      stage = .climb
      let base = tier > 0 ? 0.5 : 0
      var v = base
      if let counted = p.basis?.spend, let cap = p.basis?.target {
        let foot = tier > 0 ? tier : minimum
        let from = cap > foot ? foot : 0
        v = base + (1 - base) * Self.ratio(counted - from, cap - from)
      }
      pose = Pose(h: 1, v: v)
    case .capReached:
      stage = .capped; pose = Pose(h: 1, v: 1)   // the partial block and the exceeded cap included
    case .topTier:
      stage = .rest; pose = Pose(h: 1, v: 0.5)
    case .minimumMet:
      stage = .rest; pose = Pose(h: 1, v: 0)
    case .noTarget:
      stage = .calm; pose = Pose(h: 1, v: 0)
    }
    miles = p.rewardType == .miles
    hasMinimum = minimum > 0
    target = "\(Self.kind(p.action))|\(p.basis?.target ?? 0)|\(p.deadline?.end ?? "")"
  }

  /// A plain amount: finite and positive, else 0.
  private static func amount(_ x: Double) -> Double { x.isFinite && x > 0 ? x : 0 }
  private static func clamp(_ x: Double) -> Double { x.isFinite ? min(1, max(0, x)) : 0 }
  /// Progress over a span; a span that is not positive counts as complete.
  private static func ratio(_ x: Double, _ over: Double) -> Double { over > 0 ? clamp(x / over) : 1 }

  private static func kind(_ action: RewardRowProjection.Action) -> String {
    switch action {
    case .monthlyMinimum: "monthly"
    case .minimum: "minimum"
    case .nextTier: "tier"
    case .capHeadroom, .capReached: "cap"
    default: "none"
    }
  }
}

/// Everything else the scene needs, derived from the pose and never stored.
extension RewardExposure.Pose {
  /// How far the sun has lifted clear of the horizon, over h 0.85 to 1.
  var lift: Double { min(1, max(0, (h - 0.85) / 0.15)) }
  /// The sun's x as a share of the width, riding the marker while the minimum journey runs.
  var sunX: Double { h >= 1 ? RewardExposure.column : min(max(h, 0.07), 0.85) }
  /// The share of the full gap between the ridges that is left.
  var gap: Double { 1 - h }
  /// The sun's centre y for a target horizon at `horizon` and a disc of radius `r` (y points down).
  func sunY(horizon: Double, r: Double) -> Double {
    let sit = horizon + 0.08 * r, rest = horizon - 1.15 * r
    return h < 1 ? sit + (rest - sit) * lift : rest + (-1.05 * r - rest) * v
  }
}
```

The rings, the sun's position, the veil edge and the ridge lines are functions of `(layout, size, pose)` in `ExposureScene`, so an animated pose moves all of them together.

### `RewardExposureFace`: one `Canvas`

The face is a single `Canvas`. It is not a stack of `Shape` views.

- **One pass, one layer.** A list row needs about ten layers: sky, horizon, gold or bloom, pour, four rings, two ridges and their crests, the veil, the disc and the marker. As `Shape` views that is a dozen views per row with their own identity and diffing, times every visible row. `Canvas` draws them in one immediate-mode pass and keeps the result until its inputs change. Scrolling never redraws it.
- **Geometry stays in one place.** A pure `ExposureScene(size:layout:exposure:pose:scale:)` computes everything and the Canvas draws it. The web port mirrors the same functions.
- **One animatable pose.** The face conforms to `Animatable` with `h` and `v` as an `AnimatablePair`. SwiftUI interpolates them and the scene recomputes the sun, the light, the ridges and the marker each frame, so the sun rides the horizon in the minimum journey and goes straight up its column in the climb.
- **Text stays out.** Every word is a real `Text` outside the Canvas, so Dynamic Type, Bold Text, VoiceOver and OCR keep working. The Canvas is `accessibilityHidden(true)` and `accessibilityIgnoresInvertColors(true)`, because Smart Invert must not turn a print into a negative.

```swift
// Sketch, unverified.
struct RewardExposureFace: View, Animatable {
  var exposure: RewardExposure
  var layout: ExposureLayout          // .strip(nameBottom:footTop:), .print, .band, .hero(showsLabels:)
  var pose: RewardExposure.Pose       // animated; exposure.pose at rest
  var appearance: FaceAppearance      // .daytime or .print
  @Environment(\.displayScale) private var scale

  var animatableData: AnimatablePair<Double, Double> {
    get { AnimatablePair(pose.h, pose.v) }
    set { pose = .init(h: newValue.first, v: newValue.second) }
  }

  var body: some View {
    Canvas { context, size in
      let scene = ExposureScene(size: size, layout: layout, exposure: exposure, pose: pose, scale: scale, appearance: appearance)
      if exposure.stage == .failed { context.addFilter(.saturation(0.15)) }
      scene.drawSky(in: &context)       // sky, horizon warmth, contrail and gold (light) or bloom (dark), the pour
      scene.drawHalo(in: &context)      // rings and core glow; nothing when failed
      scene.drawRidges(in: &context)    // target horizon, spend horizon, crests
      scene.drawGround(in: &context)    // light mode: the ground's gold; dark mode, strip only: the scrim
      scene.drawVeil(in: &context)      // minimum journey only
      scene.drawSun(in: &context)       // the disc, clipped to the sky, above the veil
      scene.drawMarker(in: &context)    // minimum journey only
    }
    .accessibilityHidden(true)
    .accessibilityIgnoresInvertColors(true)
  }
}

extension ExposureScene {
  func drawVeil(in context: inout GraphicsContext) {
    let failed = exposure.stage == .failed
    guard failed || exposure.hasMarker else { return }       // nothing is veiled once the minimum is met
    let h = failed ? -0.04 : pose.h                          // failed veils everything
    var veil = context
    let rect = Path(CGRect(origin: .zero, size: size))
    let from = CGPoint(x: (h - 0.04) * size.width, y: 0), to = CGPoint(x: (h + 0.04) * size.width, y: 0)
    switch appearance {
    case .print:
      veil.blendMode = .saturation
      veil.fill(rect, with: .linearGradient(
        Gradient(colors: [.clear, Theme.Face.veilGrey.opacity(0.5)]), startPoint: from, endPoint: to))
      veil.blendMode = .multiply
      veil.fill(rect, with: .linearGradient(
        Gradient(colors: [.white, veilColour]), startPoint: from, endPoint: to))
    case .daytime:
      let alpha = failed ? 0.14 : 0.15                       // the cool dim, whole frame
      veil.fill(rect, with: .linearGradient(
        Gradient(colors: [Theme.Face.veilDim.opacity(0), Theme.Face.veilDim.opacity(alpha)]), startPoint: from, endPoint: to))
    }
  }
}
```

Past the gradient's end the end colour holds, so everything right of the falloff gets the full veil. The sun disc is drawn after the veil, so the veil never touches it.

### The strip row

The scene is the row's background. The ridges are placed from the measured name bottom `N` and headline top `F`, so long names and large text move the ridges rather than overlap them.

```swift
// Sketch, unverified.
struct RewardExposureRow: View {
  let projection: RewardRowProjection
  let text: RewardRowText
  var icon: String?
  var index = 0
  @State private var nameBottom: CGFloat?
  @State private var footTop: CGFloat?
  @State private var width: CGFloat = 0
  @ScaledMetric(relativeTo: .body) private var skyBand = 24.0

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      RewardCardTitle(projection.title, icon: icon, miles: projection.rewardType == .miles)
        .frame(maxWidth: width * 0.50, alignment: .leading)   // the sun's column and its rings stay right of here
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("exposure")).maxY } action: { nameBottom = $0 }
        .padding(.bottom, skyBand)
      VStack(alignment: .leading, spacing: 2) {
        RewardCardHeadline(projection: projection, text: text, surface: .ridge)
        RewardCardBasis(text: text, surface: .ridge)
      }
      .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("exposure")).minY } action: { footTop = $0 }
    }
    .padding(.horizontal, 16).padding(.vertical, 9)
    .frame(maxWidth: .infinity, alignment: .leading)
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    .background {
      if let nameBottom, let footTop, let exposure = RewardExposure(projection) {
        RewardExposureAnimator(exposure: exposure, layout: .strip(nameBottom: nameBottom, footTop: footTop),
          key: projection.cardID, index: index)
      }
    }
    .coordinateSpace(.named("exposure"))
    .clipShape(.rect(cornerRadius: Theme.Radius.card, style: .continuous))
  }
}
```

If the first layout pass shows a frame without a scene, seed `nameBottom` and `footTop` with estimates (about 0.31 and 0.54 of the row height) rather than drawing nothing.

### Fonts

iOS bundles no custom fonts today. Add them for the card only.

- **Files.** Instrument Serif Italic, plus IBM Plex Sans and IBM Plex Mono in Regular, Medium, SemiBold and Bold: nine static `.ttf` files, about 1.3 MB. Take them from the upstream SIL OFL 1.1 releases and match the versions `apps/web` pins through `@fontsource`. Keep the OFL texts beside them in `Fonts/` and list the fonts in any in-app acknowledgements.
- **Registration.** Add the files to `UIAppFonts` in `HowMuch/Info.plist`. Read the PostScript names from the files (Font Book or `fc-scan`); do not guess them.
- **Dynamic Type.** Always `Font.custom(_:size:relativeTo:)`, so the sizes in the strip table scale with the user's setting.
- **Bold Text.** When `legibilityWeight == .bold`, step each Plex weight up one (Regular to Medium, SemiBold to Bold). Instrument Serif has a single weight and is display-sized, so it stays.
- **Missing fonts.** `Font.custom` falls back to SF silently. Add a DEBUG-only launch assertion that each name resolves through `UIFont(name:size:)`. This is a runtime guard, not a test.

### Colour assets

Add a `Face` folder to `Assets.xcassets` with **Provides Namespace** checked, and read the colours as `Color("Face/SkyMiles1")` through a small `Theme.Face` accessor.

**Faces follow the appearance.** Version 2 first made the faces prints, constant across looks and modes. Light mode has daytime faces of its own, on both platforms:

- **Light mode: daytime.** The part still to go is a clear, slightly hazy blue sky. Progress is golden light in the halation amber (`SkyLit`, the `--glow` #FFD98C) laid over it from the left, with the same soft falloff. At `h` 0 the sky is blue with a sliver of gold at the left; from the minimum on, the whole band is a warm golden sky with no blue left, deepening as the sun climbs. The ground is a lighter, sunlit green (#A9D6B1 far, #86C396 near): gold-washed to the marker, cooled and dimmed a little beyond, never dark, so the foot text sits in dark ink.
- **Dark mode: today's prints, unchanged.** Miles is the night sky. Cashback is the warm sky version 2 called "day", now called dusk, because light mode owns the day. The ground stays the deep green with light foot ink.
- **Miles against cashback** in light mode: altitude. Miles is a higher, cooler, clearer blue with a faint contrail; cashback a warmer, softer haze with none.
- **Within a mode, faces are identical in every look** (Dusk Ridge, Ridge Charcoal, Overexposed) and on both platforms. Only the chrome differs between looks.

Each colour set is named for its role and, where it matters, the reward type, so one name resolves to the right face in either appearance: **Any** holds the light-mode value and **Dark** the dark-mode value. A set that only one mode draws carries the same value in both slots, unless the table says otherwise. Fill both slots explicitly, so nobody later "fixes" a missing value. Add a High Contrast variant where one is listed; where that column shows two values, they are Any and Dark.

| Colour set (`Face/…`) | Any (light mode) | Dark | Increase Contrast | Web token |
| --- | --- | --- | --- | --- |
| `SkyCashback1`, `2`, `3` | #8DB6D8, #BAD2E3, #EBE6DD: a warm, soft haze (stops 0, 0.48, 1 at 165°) | #7A4420, #5A3016, #3F2211: the amber dusk print | same | `--face-cashback-sky` (renames `--face-day`) |
| `SkyMiles1`, `2`, `3` | #6EA6DA, #A6C9E9, #DCEBF6: higher, cooler and clearer | #1C2013, #141C12, #0B1710: the night print | same | `--face-miles-sky` (renames `--face-night`) |
| `SkyOvercast1`, `2`, `3` | #D6D8D9, #E1E2E0, #ECEBE7: the failed sky | same; not drawn (dark mode veils the print) | same | new `--face-overcast` |
| `SkyLit` | #FFD98C, with its alpha set in code: on the sky `(0.76 + 0.16 × v) × 0.9` (0.42 × 0.9 when calm), on the ground `(0.24 + 0.12 × v) × 0.8` (0.16 × 0.8 when calm); a tenth and a fifth of that beyond the edge | same; not drawn | same | new `--face-lit` |
| `Contrail` | #FFFFFF at 45%; miles only | same; not drawn | same | new `--face-contrail` |
| `InkCashback` | #1C1B18 | #1C1B18 | same | `--face-cashback-ink` (renames `--face-day-ink`) |
| `InkMiles` | #1C1B18 | #F7F5EF | same | `--face-miles-ink` (renames `--face-night-ink`) |
| `FootInk` | #1C1B18 | #F7F5EF | same | `--face-foot-ink` |
| `FootInkSoft` | #2C3832 | #D4E2D9 | #1F2924 / #EEF4F0 | new `--face-foot-soft` |
| `UrgentInk` | #5A2F00, a dark umber | #FFD98C | #4A2600 / #FFE7B5 | new `--face-urgent-ink` |
| `FailedInk` | #701510, a dark red | #FFABAE | #5E100C / #FFD1D3 | new `--face-failed-ink` |
| `RidgeBack` | #A9D6B1, the far slope, sunlit | #2A6648 | #B8E0BF / #235741 | `--ridge-back` |
| `RidgeFront` | #86C396, the near ground, sunlit | #1E4433 | #96CCA4 / #163527 | `--ridge-front` |
| `Crest` | #FFD98C; the target crest at 40%, the spend crest at 75%, merged at 90% rising to 100% with `v` | same | 70%, 100%, 100% | `--ridge-crest` |
| `SunDiscTop`, `SunDiscBottom` | #FFFDF6, #F8E6BA | same | same | `--sun-disc-1`, `--sun-disc-2` |
| `SunRiseTop`, `SunRiseBottom` | #FFE3AE, #F0B55E: the disc while the tone is needs-minimum | same | same | `--sun-rise-1`, `--sun-rise-2` |
| `SunRim` | #DFA050, drawn at 60% | same | same | `--sun-rim` |
| `SunCore` | #FFD382 | same | same | `--sun-core` |
| `Ring1` to `Ring4` | #FFD27A at 78%, #FFA452 at 28%, #F08446 at 14%, #D8604A at 7% | same | same | `--face-ring-1` to `--face-ring-4` |
| `Horizon` | #FFAD5C at 17%; over the blue it reads as a warm haze | same | same | `--face-horizon` |
| `VeilDim` | #3D5674 at 15% × (0.1 + 0.9 × `veil`) (14% when failed): the cool dim right of the marker, a tenth of it left of it | same; not drawn | same | new `--face-veil-dim` |
| `VeilGrey` | #808080 (saturation blend, alpha 0.5 × `veil`); not drawn | #808080, saturation blend, alpha 0.5 × `veil` | same | new `--face-veil-grey` |
| `VeilCashback` | #FFFFFF; not drawn | #D4CBD4, multiply, whole frame | same | new `--face-veil-cashback` |
| `VeilMiles` | #FFFFFF; not drawn | #8A8496, multiply, whole frame | same | new `--face-veil-miles` |
| `Bloom` | #FFE3AC; not drawn | #FFE3AC at 30% × `v` over the sky | same | new `--face-bloom` |
| `Pour` | `SunDiscTop` through `SunCore` to nothing; peak alpha 0.65, set in code | peak alpha 0.45 on the dusk print, 0.65 on the night print | same | new `--face-pour` (the peak alpha) |
| `MarkerCashback` | #FFF8E6 at 85% | #FFD98C at 35% | 100% / 45% | new `--face-marker-cashback` |
| `MarkerMiles` | #FFF8E6 at 85% | #FFD98C at 35% | 100% / 40% | new `--face-marker-miles` |
| `MarkerRidge` | #FFF8E6 at 85% | #F7F5EF at 20% | 100% / 26% | new `--face-marker-ridge` |
| `MarkerEdge` | #1C1B18 at 12%, one device pixel either side of the line | clear; not drawn | 20% / clear | new `--face-marker-edge` |

Version 1's `Afterglow`, `Dim`, `PaceDay` and `PaceNight` are not needed. Version 2's `SkyDay1` to `SkyDay3`, `SkyNight1` and `SkyNight2`, `InkDay`, `InkNight`, `VeilDay`, `VeilNight`, `MarkerDay` and `MarkerNight` become the role names above, and its `SunCoreUnder` becomes `SunRiseTop` and `SunRiseBottom`. Version 3 changes only light-mode (Any) values: the urgent and failed inks, both ridges and the three markers, and it adds `MarkerEdge`, `VeilDim`, `SunRiseTop` and `SunRiseBottom` and `Pour`. Every Dark value is as version 2 left it, except that the bloom now scales with `v` and the top glow is the pour. Version 2's light-mode umber and dark-ridge markers, and its note that a warm white marker would break a floor, are withdrawn: with dark foot ink in light mode, a glyph crossing the warm white line gains contrast instead of losing it.

#### Drawing rules by appearance

| Rule | Light mode (daytime) | Dark mode (prints) |
| --- | --- | --- |
| Sky | `SkyCashback` or `SkyMiles`; `SkyOvercast` when failed | `SkyCashback` or `SkyMiles`, failed included |
| Contrail | Miles, unless failed: after the sky, before the sky's gold | None |
| Gold on the sky | `SkyLit` at `(0.76 + 0.16 × v) × (1 − veil)`; 0.42 evenly when calm; none when failed | None |
| Gold on the ground | `SkyLit` at `(0.24 + 0.12 × v) × (1 − veil)`, clipped to the ridges; 0.16 evenly when calm; none when failed | None |
| Veil | `VeilDim` at 15%, whole frame, normal blend | Whole frame, desaturation and multiply |
| Foot scrim | None | `RidgeFront` at 55%, strip only |
| Rings and core glow | Screen | Screen on miles, normal on cashback |
| Bloom | None | `Bloom` at 30% × `v`: screen on miles, normal on cashback |
| Pour | Screen, peak 0.65, radius 0.62 W (hero 0.78 W) | Screen on miles (peak 0.65, radius 0.35 W), normal on cashback (peak 0.55, radius 0.62 W; hero 0.78 W) |
| Marker | One warm white line (`MarkerCashback`, `MarkerMiles` and `MarkerRidge` are all #FFF8E6) over `MarkerEdge` | Two tones: `MarkerCashback` (umber) or `MarkerMiles` (gold) on the sky, `MarkerRidge` (pale) on the ridges; no edge |
| Title ink | `InkCashback` or `InkMiles`, both dark | `InkCashback` (dark) or `InkMiles` (light) |
| Foot inks | `FootInk`, `FootInkSoft`, `UrgentInk`, `FailedInk`: all dark | All light |

**The contrail.** Two short parallel hairlines high in the right of the sky, a hair apart (0.7% of the width on the strip and the print, 0.4% on the hero): from 0.50 W at 30% of the frame's height to 0.76 W at 20% on the strip and the print, and from 0.56 W at 30% to 0.80 W at 21% on the hero and the web's 3:2 face. They always stay right of the name column and at least 4pt above the target horizon; tune them on the strip. Each is 1.4 units wide on a 1,000-wide scene, in `Contrail` at 45%, brightest over its middle and fading to nothing at both ends. The sky's gold is drawn over them, so they show only on the blue, fade as the light passes them, and are all but gone once the whole band is lit. They are static: they never move with the pose, and the sun's column passes behind them.

#### Picking the face by appearance (iOS)

- **Colours resolve themselves.** A `Canvas`'s `GraphicsContext` resolves each `Color` in the canvas's environment, so `colorScheme` picks the Any or Dark slot and `colorSchemeContrast` the High Contrast slot. No colour is chosen with an `if`. Never resolve a face colour through `UIColor(named:)` or `UITraitCollection.current`: both ignore an `.environment(\.colorScheme, …)` override, so a dark snapshot or preview would draw the daytime face.
- **The rules switch on the appearance.** `RewardExposureAnimator` reads `@Environment(\.colorScheme)` and passes `appearance: FaceAppearance` (`.daytime` or `.print`) into the face as a stored property, so the face's `Equatable` check sees a mode change and redraws. `ExposureScene` takes it and applies the table above.
- **The reward type picks the set.** `RewardExposure.miles` picks the miles or cashback sets. `RewardCardTitle` reads `InkMiles` or `InkCashback` from the type alone (the strip sketch's `miles:` is that flag), and the appearance does the rest.
- **Smart Invert** still leaves the faces alone in both modes.

```swift
// Sketch, unverified.
enum FaceAppearance: Equatable { case daytime, print }   // light mode, dark mode

extension ExposureScene {
  var sky: [Color] {                                     // each set resolves Any or Dark itself
    if appearance == .daytime, exposure.stage == .failed { return Theme.Face.skyOvercast }
    return exposure.miles ? Theme.Face.skyMiles : Theme.Face.skyCashback
  }
  /// Peak alpha of the gold on the sky and on the ground, or nil when there is none.
  var litAlpha: (sky: Double, ground: Double)? {
    guard appearance == .daytime else { return nil }
    switch exposure.light {
    case .overcast: return nil
    case .even: return (0.42, 0.16)
    case .journey: return (0.76 + 0.16 * pose.v, 0.24 + 0.12 * pose.v)
    }
  }
  var glowBlend: GraphicsContext.BlendMode { appearance == .daytime || exposure.miles ? .screen : .normal }
  /// The pour's peak alpha and radius (a share of the width).
  var pour: (peak: Double, radius: Double) {
    let night = appearance == .print && exposure.miles
    let peak = appearance == .print && !exposure.miles ? 0.55 : 0.65
    return (peak, night ? 0.35 : layout.isHero ? 0.78 : 0.62)
  }
  var drawsScrim: Bool { appearance == .print && layout.isStrip }
}
```

Each lit wash is one `linearGradient` fill across the frame: `SkyLit` at its alpha from the left edge to `(h − 0.04) W`, falling to nothing at `(h + 0.04) W`. From the minimum on (`h` 1) it covers the whole band. When calm it is its calm alpha throughout.

**Reference.** The lab page shows both appearances side by side and is the visual reference for these faces. Where its values differ from the table, the lab wins, except where a value breaks a floor below:

- the night print's pour, which the lab draws at 0.62 W or 0.78 W and 0.8 peak. That takes `InkMiles` to 2.6:1 at the end of the name over the bloom, so the night print's pour is 0.35 W at 0.65;
- the dark prints' veil, which the lab draws as a plain #262330 dim at 44% to 58%. That takes `InkCashback` to 4.4:1 on the darkest dusk stop, so the dark veil stays version 2's gentler saturation and multiply pair.

Re-measure every pair in the contrast tables when a value changes; a value that breaks a floor does not ship.

**Contrast on the faces.** WCAG relative luminance, computed from the values above with sRGB compositing (the saturation filter as the CSS `saturate()` matrix defines it); confirm with the OCR snapshot and Accessibility Inspector in both appearances. The requirements:

- Every text pair is at least 4.5:1, in both appearances, at default and Increase Contrast.
- Dark ink on the sky (the name, and the issuer line on the web's 3:2 face) clears it on the blue, on the dimmed blue, on the gold, through the falloff between them, on the calm wash, under the pour and over rings 3 and 4.
- Foot ink clears it on the ground, lit, unlit and failed.
- Text that crosses the marker keeps at least 4.5:1 against the marker pixel.
- The marker stays faint: about 1.5 to 2.5:1 in dark mode; in light mode, as measured below, as a decorative non-text mark.

**Light mode (daytime faces).** Ranges cover both reward types, the three sky stops and the gold's alpha from 0.76 to 0.92.

| Text or mark | Background | Ratio |
| --- | --- | --- |
| `InkCashback` | `SkyCashback1` to `3`, the unlit blue; under the 15% dim | 8.0 to 13.9:1; 6.9 to 11.2:1 |
| `InkMiles` | `SkyMiles1` to `3`, the unlit blue; under the 15% dim | 6.7 to 14.2:1; 5.8 to 11.4:1 |
| `InkCashback`, `InkMiles` | `SkyLit` over the blue: the gold | 10.9 to 13.0:1 |
| `InkCashback`, `InkMiles` | the falloff's midpoint, half gold and half blue | 8.9 to 13.4:1, never below the blue figure |
| `InkCashback`, `InkMiles` | calm: `SkyLit` at 42% over the blue | 8.7 to 13.5:1 |
| `InkCashback`, `InkMiles` | the pour over the gold | Above the gold figure: the pour only lightens |
| `InkCashback`, `InkMiles` | rings 3 and 4 screened over the blue, dimmed or not, or the gold | 5.8 to 14.4:1 |
| `InkCashback`, `InkMiles` | a marker pixel over the sky | 14.2 to 15.9:1 |
| `InkCashback`, `InkMiles` | `SkyOvercast1` to `3` under the 14% dim, at saturation 0.15 | 10.0 to 11.8:1 |
| `FootInk`, `FootInkSoft`, `UrgentInk` | `RidgeFront` | 8.4, 6.0, 5.6:1 |
| `FootInk`, `FootInkSoft`, `UrgentInk` | `RidgeFront` under the 15% dim: the unlit ground | 7.1, 5.0, 4.7:1 |
| `FootInk`, `FootInkSoft`, `UrgentInk` | `RidgeFront` under the ground's gold, 0.24 to 0.36 | 9.2 to 9.7, 6.6 to 6.9, 6.1 to 6.4:1 |
| `FootInk`, `FootInkSoft`, `UrgentInk` | a marker pixel over the ground | 14.5 to 15.3, 10.3 to 10.9, 9.6 to 10.1:1 |
| `FailedInk`, `FootInkSoft` | `RidgeFront` under the 14% dim, at saturation 0.15 | 4.7, 5.0:1 |
| `FootInk`, `FootInkSoft`, `UrgentInk`, Increase Contrast | `RidgeFront`, Increase Contrast; the same under the dim | 9.4, 8.2, 7.3:1; 7.9, 6.9, 6.1:1 |
| `FailedInk`, Increase Contrast | `RidgeFront`, Increase Contrast, dimmed, at saturation 0.15 | 6.1:1 |
| Marker (non-text) | the gold; the pale sky and the saturated blue (dimmed or not); `RidgeFront`, lit or not; `RidgeBack` | 1.2 to 1.3:1; 1.1 to 2.5:1; 1.6 to 2.0:1; 1.4 to 1.7:1 |
| `MarkerEdge` (non-text) | either side of the line, on any background | 1.25:1 |
| Ridge gap (non-text) | `RidgeBack` against `RidgeFront`; Increase Contrast | 1.26:1; 1.26:1 |
| Skyline (non-text) | `RidgeBack` against the lower blue; against the lower gold; the merged `RidgeFront` against the gold | 1.0 to 1.3:1; 1.1 to 1.2:1; 1.4 to 1.6:1, with the hue step from gold to green |
| `Contrail` (non-text) | `SkyMiles1` | 1.6:1 |
| Lit against unlit (non-text) | the gold against the dimmed blue; the gold-washed ground against the dimmed ground | 1.3 to 2.1:1; 1.3:1, a hue step |

The ridge gap and the skyline are decorative too: the gap is the remainder the headline states, and the crest strokes and the sun carry the same read.

**Dark mode (the prints).** Unchanged from version 2, plus the climb's bloom and pour.

| Text or mark | Background | Ratio |
| --- | --- | --- |
| `FootInk` | `RidgeFront` | 10.0:1 |
| `FootInkSoft` | `RidgeFront` | 8.1:1 |
| `UrgentInk` | `RidgeFront` | 8.1:1 |
| `FootInk` | `RidgeFront` under the night veil | 15.4:1 |
| `FailedInk` | `RidgeFront`, veiled, at saturation 0.15 | 9.4:1 |
| `InkCashback` | `SkyCashback3`, the darkest dusk stop | 10.3:1 |
| `InkCashback` | `SkyCashback3` under the dusk veil | 6.6:1 |
| `InkCashback` | the dusk print under the full bloom and the pour | 11.3:1 or more |
| `InkMiles` | `SkyMiles1` | 15.2:1 |
| `InkMiles` | the night print under the full bloom; with the pour's edge at the end of the name column | 6.2 to 7.0:1; 5.0 to 5.6:1 |
| `InkCashback`, `InkMiles` | a sky marker pixel on their sky; Increase Contrast | 5.5:1, 5.7:1; 4.9:1, 4.9:1 |
| `FootInk`, `FootInkSoft`, `UrgentInk` | a ridge marker pixel on `RidgeFront`; the Increase Contrast inks on the Increase Contrast marker and ridge | 5.7, 4.6, 4.6:1; 5.6, 5.5, 5.1:1 |
| `MarkerCashback` (non-text) | dusk sky stops; veiled `SkyCashback3` | 1.9 to 2.1:1; 1.5:1 |
| `MarkerMiles` (non-text) | night sky, veiled or not | 2.7:1 |
| `MarkerRidge` (non-text) | `RidgeFront`, `RidgeBack` | 1.75:1, 1.55:1 |

At version 2's first 22%, the pale ridge marker left `FootInkSoft` and `UrgentInk` at 4.4:1 where a glyph crossed it, and the Increase Contrast markers (75%, 55%, 35%) took the inks crossing them down to between 3.3 and 4.3:1. Hence the current opacities. Without the night print's 0.35 W pour radius, a pour reaching the name at full strength would take `InkMiles` down to 2.6:1; hence the limit.

Text never sits on the back ridge or across a crest stroke.

### Performance with 20 or more cards

- `List(.plain)` is already lazy. One Canvas per realised row, with no `.blur`, `.shadow`, material, `.drawingGroup()` or `TimelineView` per row. Rings are radial gradients, the dark veil is two linear-gradient fills with blend modes (light mode's is one), the bloom and the pour are one fill each, light mode's two gold washes are two more, and monochrome is one colour-matrix filter.
- The face is `Equatable` on (exposure, layout, pose, appearance) and applied with `.equatable()`. `RewardsBoard` is rebuilt on every `body` (`Views/RewardsView.swift:158-160`), and unchanged cards must not redraw.
- Build ridge paths once per layout as unit paths, scale them with a transform, and keep the crest table `static`. The spend line is a per-frame blend of two sampled lines (65 points), which is cheap.
- Only animating rows redraw per frame: at most the visible rows (about five) for 0.6s after data arrives.
- The context-menu preview renders the same row, and the swipe action is unchanged.
- **Check:** the 30-card fixture below, flung top to bottom and back, with Instruments' Animation Hitches template. The simulator gives an indication only. Real evidence needs a device run, which needs a signed build the owner authorises.

## Motion

Timings are `Theme.Motion` (`Support/Theme.swift:180-189`). The web uses the same values through its tokens (`--dur-fill` 600ms, `--dur-standard` 320ms, `--dur-arrive` 400ms, `--stagger` 28ms). Only the pose animates: `h` and `v`. Everything in the art is recomputed from it.

| Moment | Animation | Reduce Motion |
| --- | --- | --- |
| A card is first shown this session | The List's existing arrival (`arrive`, 0.4s). The pose moves from its journey's start to its value with `chart` (0.6s), staggered 28ms × min(index, 12). A card in the minimum journey starts at `h` 0: the lit edge sweeps right, the sun rides the marker along the horizon, and the spend line lifts. A card that has had a minimum journey sweeps first and then rises, the sweep taking the first 40% of the glide; a card without one starts resting in its column and the sun climbs straight up to its height (a capped card's sun climbs off the top). Calm and failed cards are drawn in place. | Drawn in place. No rise. |
| Scrolled back into view | Nothing: it was already shown | Same |
| Same target, new figures (refresh, a new transaction, the as-of date stepped) | The pose glides with `chart`: across in the minimum journey, up in the climb. A refund may glide it back. Figures crossfade in place over 0.18s with `.contentTransition(.opacity)`. | The pose jumps. Figures crossfade, since opacity is allowed. |
| The minimum is met | One glide with `chart`: the lit edge sweeps to the right edge, the spend line meets the target horizon, the marker goes, and the sun, already near its column, lifts clear of the horizon to rest just above the ground. If spend has gone past the minimum, or the minimum and a tier are reached together, the sweep takes the first 40% of the glide and the sun climbs on in the rest. | Jump |
| A tier is reached, or the climb passes from the tier to the cap | `v` glides on up. Never a step, never back. | Jump |
| A refresh reaches the cap | `v` glides to 1 with `chart`: the sun climbs off the top edge, and the gold and the pour grow with it. No separate sunset. | Jump to capped |
| A target change where a value would fall (a new period or month) or the light changes (journey, even or overcast) | The face crossfades over 0.32s (`standard`) to the new state. The marker never glides backwards and the sun never sinks. | Jump |
| Tap | Scale 0.99 with `press` (0.18s), no opacity change. Today's `PressableButtonStyle` (0.97 and 0.85) is too strong for a picture. | Opacity 0.9, no scale |
| Opening the sheet | The system sheet. A zoom from row to hero is optional (see the open questions). | System |
| Idle | Nothing. No `TimelineView`, shimmer, pulse or drifting rings. | Same |

**Interpolation.** The pose interpolates through `animatableData`, and the scene places the sun for each frame's pose: along the horizon at `h × W` while the minimum journey runs, lifting over `h` 0.85 to 1, then straight up its column. The marker and the lit edge move in step with the sun. Where `h` and `v` both rise in one change, interpolate `h` over the first 40% of the glide and `v` over the rest (a keyframe animation on the pair, or two chained `withAnimation` calls), so the sun never moves diagonally. Use `Theme.Motion.chart`, which is `.smooth` with no bounce. Never use a bouncy spring: overshoot would briefly show progress the ledger has not reached, or drop a capped sun back into the frame.

**No counting.** Text never counts. Use `.contentTransition(.opacity)` only. Never use `.numericText` or the register's `.rollingNumber` (`Views/Components.swift:186-195`) on the card.

**Rising once.** A lazy `List` creates rows again as they scroll, so `onAppear` alone would replay the rise. Keep the last pose shown per card, with its target, in a session-only memory keyed by plan and card. A row that appears starts from the remembered pose when the target is the same (or from its journey's start the first time), and animates only if the value differs. If the target changed while the row was off screen, it appears in place.

```swift
// Sketch, unverified.
@MainActor @Observable final class ExposureMemory {
  var shown: [String: (target: String, pose: RewardExposure.Pose)] = [:]   // plan | card
}

struct RewardExposureAnimator: View {
  let exposure: RewardExposure
  let layout: ExposureLayout
  let key: String
  var index = 0
  @Environment(ExposureMemory.self) private var memory
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme
  @State private var shown: RewardExposure.Pose?
  @State private var faceID = ""     // changes only when a target change falls or relights

  var body: some View {
    RewardExposureFace(exposure: exposure, layout: layout, pose: shown ?? exposure.pose,
      appearance: colorScheme == .dark ? .print : .daytime)
      .equatable()
      .id(faceID)
      .transition(.opacity)
      .onAppear {
        let last = memory.shown[key]
        let start = last.map { $0.target == exposure.target ? $0.pose : exposure.pose } ?? exposure.journeyStart
        faceID = "\(exposure.target)|\(exposure.light)"
        shown = reduceMotion ? exposure.pose : start
        memory.shown[key] = (exposure.target, exposure.pose)
        guard !reduceMotion, start != exposure.pose else { return }
        withAnimation(Theme.Motion.chart.delay(Double(min(index, 12)) * 0.028)) { shown = exposure.pose }
      }
      .onChange(of: exposure) { old, new in
        memory.shown[key] = (new.target, new.pose)
        // A changed light always swaps (failed, calm and journey can share a target); a changed target only where it would fall.
        if new.light != old.light || (new.target != old.target && new.pose.falls(from: old.pose)) {
          // Never glide backwards or sink the sun: swap the face and crossfade.
          withAnimation(reduceMotion ? nil : Theme.Motion.standard) { faceID = "\(new.target)|\(new.light)"; shown = new.pose }
        } else {
          withAnimation(reduceMotion ? nil : Theme.Motion.chart) { shown = new.pose }
        }
      }
  }
}
```

Confirm on device that the `.id` swap crossfades inside a List row's background, and fall back to an explicit two-face `ZStack` with opacity if it does not.

Also fix the list-wide `.animation(Theme.Motion.arrive, value: model.rewardsPhase)` (`Views/RewardsView.swift:186`), which does not check Reduce Motion today.

## Accessibility

- **One element per card, as today.** The label is the card name, the value is `RewardRowText.accessibilityValue`, the hint is "Shows details.", and the custom actions are Edit Rewards and Hide (`Views/RewardsView.swift:396-404`). The register row keeps "Rewards, <name>" and its hint (`:1720-1722`). The slip is part of the same element. The face, emoji and every in-frame label are hidden.
- **Nothing new is spoken.** The value string stays pinned by `testAccessibilityValueStatesTargetProgressAndDeadline` (`apps/ios/HowMuchTests/RewardsReportTests.swift:1413`). `h` and `v` are picture coordinates and are never spoken: the spoken percentage stays the basis's, even where it differs from the sun's height. The art stays decorative. The issuer, newly visible in the sheet, is offered through `accessibilityCustomContent("Issuer", issuer)` in the More Content rotor, and "Featured" the same way when it applies.
- **Dynamic Type.** Every font is relative to a text style, and padding uses `@ScaledMetric`. The strip grows with its text. At accessibility sizes, every row becomes the paper row with a band, so text never sits on fixed-ratio art.
- **Contrast on the faces.** See the contrast tables, one per appearance. Text sits only on the sky above the target horizon or on the spend ridge, and never across a crest stroke or over rings 1 and 2. In dark mode the dusk veil is capped so dark ink keeps 6.6:1 on it, and the night print's pour stops short of the name. In light mode the cool dim is 15%: dark ink keeps at least 5.8:1 on every sky, gold or blue, and the foot inks at least 4.7:1 on the ground, lit or not.
- **Increase Contrast.** Today's 1pt outline at `Color.primary` 30% stays, on the strip and on the print. The High Contrast colour sets darken the dark-mode ridges and lighten its foot inks, and in light mode lighten the ground and darken its foot inks. The crest strokes and the marker draw at their Increase Contrast opacities.
- **Differentiate Without Colour.** Each state differs in shape and luminance, not just colour: the marker's position, the lit edge (a luminance step, and in light mode a hue step as well), the ridge gap, the sun's place (on the horizon, resting, halfway, gone), the ring size, a sun or none, plus the headline words.
- **Smart Invert.** Faces ignore invert, like photographs.
- **Reduce Transparency.** Nothing to change: there is no material, and figures stay on opaque surfaces.

## Web parity

The web face already draws a sky, the brand ridges and a sun. Parity means the web takes the iOS row's rules and the same stage, pose, marker and ridge model, so both platforms show the same state for the same report.

### 1. Port the projection, tests first

Per `AGENTS.md`, isolation is justified here. The web's R1 helpers (`cardTone`, `capIsPrimary`, `cardFill` at `apps/web/src/pages/Rewards.tsx:481-505`) have concrete bugs that the browser recipe only catches for states its fixture reaches:

- an intermediate cap is marked complete;
- a failed qualification shows before its month closes;
- the server's `minimum_spend_progress` drives the fill.

The rounding and Singapore-day rules have edge cases no fixture reaches.

- **Write the tests first.** Create `apps/web/src/lib/reward-row-projection.test.ts` before any implementation. Port every case of `RewardRowProjectionTests` with the Swift test name in each test title and the same hand-derived expected strings, plus the mapping walk and the edge cases below. Configure the same SGD format the Swift tests use (`configureMoney` in `apps/web/src/lib/money.ts`). Run it red against a stub that exports only the types.
- **Then the module.** `apps/web/src/lib/reward-row-projection.ts` exports `projectRow(row, asOf, isRange)`, `rowText(projection)`, `boardSummary(report, projections)`, `exposure(projection)`, the crest table and the scene helpers (`exposureScene(layout, size, exposure, pose)`: sun centre, ring radii, veil edge and strength, gold alphas, bloom, pour, marker x and its split at the horizon, and both ridge path strings). `projectRow` builds `minimumAmount` from `calculation.minimum_spend` and `reachedTierThreshold` from `calculation.active_spending_tier_id` looked up in `row.card.spendingTiers`, as iOS does; the types already carry both (`apps/web/src/api/types.ts:364-382`). Civil dates use string parts and `Date.UTC`, never a local `Date`.
- **Run it** with `bun test apps/web/src/lib/reward-row-projection.test.ts`, and again under `TZ=America/Los_Angeles` and `TZ=Pacific/Kiritimati` for the deadline days.

### 2. `Rewards.tsx`

- Delete `cardTone`, `capIsPrimary` and `cardFill`. `RewardCard` (`:543-569`) builds one projection and one exposure per row and sets:
  - `data-tone` (needs, earning, complete, failed or neutral, from the projection);
  - `data-stage` (gate, climb, rest, capped, calm or failed) and `data-mono` for failed;
  - inline `--rw-h` and `--rw-v` at rest, replacing `--rw-p`. Drop version 1's `--rw-t` and `--rw-base` and version 2's `--rw-e`.
- **The face** (`RewardTile`, `:694-701`):
  - The CSS-positioned sun and halo spans stay, so they stay circular, now placed by `--sun-x` and `--sun-y`.
  - The ridge SVG (`preserveAspectRatio="none"`) gains the two computed ridge paths (target horizon and spend horizon) with their crests, the veil rects, the two gold rects (sky and ground), the pour, and the marker's two `<line>` segments over its edge line. Strokes use `vector-effect: non-scaling-stroke`, and the marker adds `shape-rendering: crispEdges`.
  - The brand paths at `:698-700` become the target horizon's source shape and the crest table.
- **Animation.** The pose is tweened by a small new `apps/web/src/lib/exposure-tween.ts`: `requestAnimationFrame` over the computed `--dur-fill` with the `--ease-out` curve, starting after `--stagger` × min(index, 12) on first show, from the journey's start as on iOS. Each frame it writes the scene's CSS variables and path `d` attributes through refs, so React does not re-render per frame. Under reduced motion `tokens.css:102-108` zeroes `--dur-fill`, so the tween jumps. The tween keeps the sun on the horizon in the minimum journey and in its column in the climb in every browser, sweeping `h` over the first 40% of a glide and then raising `v` where both change, and Safari cannot transition `d`. A falling or relighting target change swaps the face with the existing opacity transition instead of tweening back.
- **The slip.** The slip (`RewardTile`, `:682-792`) replaces the R2 placeholder at `:718` with the headline: the amount in IBM Plex Mono, the label, and `<span className="rw-deadline" data-urgent>`. Then come the basis line and the exceptions (at most 2, then "+N more").
- **Featured.** The `✦` badge (`:704`) becomes the word: "Featured" joins the caps line as text on the desktop face. The badge's `title` and the screen-reader span go. The phone strip has no caps line and no Featured mark.
- The two `ExposureMeter`s, the Spend, Eligible and Value stats, and "Consider another card" move into the disclosure, renamed **Targets, periods and tiers**. On desktop the flag list stays in the slip. On phones it moves into the disclosure, matching iOS, which keeps categories in the sheet.
- The hero's R2 placeholder (`:210`) becomes the ported summary line, for example "2 below minimum · 1 capped".

### 3. `rewards-board.css` and `tokens.css`

- **Tokens.** Replace `@property --rw-p` (`tokens.css:16`) with `@property --rw-h` and `--rw-v`. The face tokens (`tokens.css:77-88`) follow the mode through the same cascade as the chrome: light values on `:root` (block 1), dark overrides in `:root[data-mode="dark"]` (block 2). The per-look blocks (3 and 4) never set a face token, so faces stay identical across Dusk Ridge, Ridge Charcoal and Overexposed within a mode; the looks differ only in chrome colour. `rewards-board.css` switches only on `data-type` and `data-stage` and has no `data-mode` selector: the tokens carry the mode. Rename the four shipped tokens as below, and delete `--face-dim` with the sunset rules.

  | Token | `:root` (light) | `:root[data-mode="dark"]` |
  | --- | --- | --- |
  | `--face-cashback-sky` (was `--face-day`) | `linear-gradient(165deg, #8db6d8 0%, #bad2e3 48%, #ebe6dd 100%)` | `linear-gradient(165deg, #7a4420 0%, #5a3016 48%, #3f2211 100%)` |
  | `--face-miles-sky` (was `--face-night`) | `linear-gradient(165deg, #6ea6da 0%, #a6c9e9 48%, #dcebf6 100%)` | `linear-gradient(165deg, #1c2013 0%, #141c12 48%, #0b1710 100%)` |
  | `--face-overcast` | `linear-gradient(165deg, #d6d8d9 0%, #e1e2e0 48%, #ecebe7 100%)` | `none` |
  | `--face-cashback-ink` (was `--face-day-ink`) | `#1c1b18` | `#1c1b18` |
  | `--face-miles-ink` (was `--face-night-ink`) | `#1c1b18` | `#f7f5ef` |
  | `--face-foot-ink` | `#1c1b18` | `#f7f5ef` |
  | `--face-foot-soft` | `#2c3832` | `#d4e2d9` |
  | `--face-urgent-ink` | `#5a2f00` | `#ffd98c` |
  | `--face-failed-ink` | `#701510` | `#ffabae` |
  | `--ridge-back` | `#a9d6b1` | `#2a6648` |
  | `--ridge-front` | `#86c396` | `#1e4433` |
  | `--face-scrim` | `transparent` | `#1e44338c` |
  | `--face-lit` | `#ffd98c` | `transparent` |
  | `--face-contrail` | `#ffffff73` | `transparent` |
  | `--face-veil-dim` | `#3d567426` | `transparent` |
  | `--face-veil-cashback` | `#ffffff` | `#d4cbd4` |
  | `--face-veil-miles` | `#ffffff` | `#8a8496` |
  | `--face-veil-grey` | `transparent` | `#808080` |
  | `--face-bloom` | `transparent` | `#ffe3ac` |
  | `--face-cashback-blend` | `screen` | `normal` |
  | `--face-pour-cashback` | `0.65` | `0.55` |
  | `--face-pour-miles` | `0.65` | `0.65` |
  | `--face-marker-cashback` | `#fff8e6d9` | `#94591a8c` |
  | `--face-marker-miles` | `#fff8e6d9` | `#ffd98c59` |
  | `--face-marker-ridge` | `#fff8e6d9` | `#f7f5ef33` |
  | `--face-marker-edge` | `#1c1b181f` | `transparent` |

  The Increase Contrast values follow the colour-asset table through the existing `prefers-contrast: more` blocks. Constant, on `:root` only: `--sun-rise-1` #ffe3ae and `--sun-rise-2` #f0b55e, beside the shipped `--ridge-crest`, `--sun-core`, `--sun-disc-1`, `--sun-disc-2`, `--sun-rim`, `--face-ring-1` to `--face-ring-4` and `--face-horizon`. The foot inks, which version 2 kept constant, now follow the mode. How the face uses the switches:
  - `.rw-face` paints `var(--face-cashback-sky)`, and miles `var(--face-miles-sky)`. `[data-stage="failed"]` layers `var(--face-overcast)` over the type's sky, so `none` in dark mode leaves the print.
  - The sky's gold is one `<rect>` in the sky layer, under the ridges, and the ground's gold one `<rect>` clipped to the ridges, both filled with a horizontal gradient of `--face-lit`. The tween writes their stop opacities (on the sky `0.76 + 0.16 × v`, on the ground `0.24 + 0.12 × v`, to `(h − 0.04)` of the width, falling to nothing by `(h + 0.04)`; 0.42 and 0.16 evenly when calm), and the end stop keeps the colour at zero opacity. In dark mode `transparent` draws nothing.
  - The contrail is two parallel `<line>`s stroked with `--face-contrail`, faded at both ends, drawn before the sky's gold and only for `[data-type="miles"]`.
  - The cashback halo and rings take `mix-blend-mode: var(--face-cashback-blend)`; miles keeps its screen rule (`rewards-board.css:548`).
  - The foot scrim is the shipped gradient under the foot, now `var(--face-scrim)`, so light mode draws none.
- **Sun and halo** (`:529-565`): place them from the scene, not the fixed 76% column. The disc is drawn after the veil and clipped to the sky; the halo (four stacked circles of radius `R` times 0.27, 0.46, 0.68 and 0.92, and a core of 0.15 `R`) sits behind the ridges.

  ```css
  /* Sketch. --sun-x and --sun-y are written by the tween from exposureScene. */
  .rw-face-sun { left: var(--sun-x); top: var(--sun-y); }
  .rw-face-halo { background: radial-gradient(circle at var(--sun-x) var(--sun-y), /* shipped bands, scaled by R */); }
  ```

- **The pour.** One `<rect>` over the sky filled with a radial gradient centred at the sun's column on the top edge (`--sun-disc-1` at the centre, `--sun-core` at 30% of the radius, nothing at the radius); the tween writes its opacity (`peak × clamp((v − 0.4) / 0.6)`, the peak from `--face-pour-cashback` or `--face-pour-miles`) and its radius (0.62 W, hero and desktop face 0.78 W, miles in dark mode 0.35 W). The bloom's own opacity is `0.3 × v`, dark mode only.
- **Rings.** The halo's radius is `R = (0.14 + 0.24 × v) × W` (on the phone strip also capped at `(0.42 + 0.6 × v)` of the height), so there is no ring gating attribute: the tween writes `--halo-r`.
- **Veil.** Light mode: one `<rect>` across the face with a horizontal gradient from `(h − 0.04)` to `(h + 0.04)` of the width, filled with `--face-veil-dim` (`transparent` in dark mode). Dark mode: two `<rect>`s with the same gradient, one with `mix-blend-mode: saturation` (`--face-veil-grey`), one with `mix-blend-mode: multiply` (`--face-veil-cashback` or `--face-veil-miles` by `data-type`; white in light mode, where the pair is not drawn). The face is already `isolation: isolate`. Every stage but `gate` and `failed` hides them; `[data-stage="failed"]` sets them to full strength everywhere, with the light-mode dim at 14%.
- **States.**
  - Delete the `[data-tone="complete"]` sunset rules (`:649-664`): a cap is now `[data-stage="capped"]`, with the sun off the top, the gold and the pour, and no dim.
  - `[data-mono]` replaces `saturate(0.35)` (`:666-668`) with 0.15, and hides the sun and halo.
  - `[data-stage="gate"]` takes over the `needs` core rule (`:644-646`), so the amber disc follows the stage.
  - Delete the `rw-expose` keyframe (`:476-480`) and the `--rw-p` transition and `rw-expose` animation on `.rw-card` (`:464-465`): the tween replaces them. `rw-arrive` stays.
- **Phones** (`@media (max-width: 720px)`, `:1087`): the card becomes the strip. The name sits on the sky, and the headline and basis line sit on the spend ridge. `N` and `F` are measured with a `ResizeObserver`. The slip carries exceptions only. This replaces the 21:9 face.

### 4. Not in this slice

The web board keeps its own Arrange orders (Manual, Name, Reward value, Spend) and has no detail sheet, so there is no web hero or period track. The `/rewards/:cardId` edit page could take the hero later.

## Verification

iOS checks run on the Mac runner through `scripts/ios-xcodebuild.sh` and the Simulator (see `apps/ios/AGENTS.md`). Linux cannot run them. Store every artifact under `.amp/in/artifacts/rewards-exposure/{ios,web}/`, which overrides the older paths in the recipes.

### Failure modes first

| # | Failure mode | Caught by |
| --- | --- | --- |
| 1 | Picture and figure disagree: `h` from anything but the projection's `fill`, `fill` from server progress fields, a capped card drawn below the top, or a figure bent to match the picture | iOS: the existing projection tests, where fill and basis share one source. Web: the port's tests, written first. E2E: measure each fixture card's marker x (`h × W`) and sun centre against its expected pose. |
| 2 | Web precedence wrong: intermediate cap set as complete, failure shown before its month closes, rewards implied unlocked | The port's tests, written first; E2E cards E, J, K and L |
| 3 | The journeys mixed or the climb mis-measured: a tier drawn in the minimum journey, the cap climb read from 0 (a jump at the minimum), the reached tier ignored (a jump at the tier), a further tier sinking the sun, any value falling as spend grows | **The isolated mapping walk, written first** (below). E2E cards O and P show one point each. |
| 4 | Picture data missing or out of step with the report: no minimum amount or reached tier, a next tier at or below the minimum, a cap at or below the foot of the climb, counted spend lagging raw spend, refunds below zero, amounts that are not finite | **The isolated edge cases, written first** (below). No fixture reaches them. |
| 5 | Time leaks back into the art: equal `h` drawn at different places in rows with different dates | E2E: cards A and B share $315.50 / $500.00 with different periods and deadlines. Their marker x and sun centre must match within 1pt. |
| 6 | Text illegible on the art: the marker or the dusk veil under a long name, the pour behind a name at night, dark ink on the light ground under the gold or on the desaturated side, the umber urgent ink, light ink on a light sky in dark mode | The existing OCR snapshot test, retargeted; E2E card N (a long name over the marker at `h` 0.63) and card B (urgent) in light, dark, AX3 and Increase Contrast |
| 7 | The light does not read: blend modes or the lit washes dropped by a renderer, so the right side is not dim, or not blue | E2E: sample pixels on card A's sky and ground 10% left and 15% right of the marker. Dark mode: the right sample must be darker and less saturated, on the dusk and night prints. Light mode: the left sky sample must be gold (red channel above blue) and the right one blue (blue above red), and the left ground sample warmer (red minus blue larger) than the right, on both reward types. |
| 8 | VoiceOver drifts: the art becomes focusable or the value string changes | The existing pinned value test (`:1413`); an E2E accessibility dump showing one element per card |
| 9 | The rise replays on every scroll, plays under Reduce Motion, or moves a sun off its axis (a diagonal sweep on first show) | E2E recordings |
| 10 | A falling change glides the marker backwards or sinks the sun instead of crossfading | E2E: card K across its month end (step 9) |
| 11 | Overshoot shows progress the ledger has not reached, or drops a capped sun back into the frame | E2E recording at 60fps, reviewed frame by frame where each glide ends |
| 12 | Fonts not bundled, falling back to SF silently | E2E screenshots and the DEBUG launch assertion |
| 13 | Scroll hitches with 20 or more cards | E2E with the 30-card fixture and Instruments; a device run by the owner |
| 14 | Dynamic Type clips text in a fixed frame | E2E at AX3; the existing snapshot at `.accessibility1` |
| 15 | The partial-block cap reads as not capped | E2E card G, checked against the rule above; the walk crosses a partial block |

### Isolated tests: only these, written before the implementation

The pure mapping (projection to `h`, `v`, the marker, the sun's x and y and the ridge gap) is the one place where isolation earns its keep: the other checks reach it only at the handful of points the fixture cards sit on. Write the tests first, run them red against a stub that exports only the types, then write the mapping. They live in `RewardExposureTests` beside `RewardRowProjectionTests` on iOS and in the port's suite on the web. Expected values come from the rules in this document, never from the implementation. Each test row sets the calculation's `minimum_spend` and `active_spending_tier_id` and the card's `spendingTiers` as well as the server's figures.

The plausible failure modes, and which of them the end-to-end fixture cards miss, are in the table above (3, 4, 15). The tests cover only the ones it misses. For the sun's y, the tests pass a target horizon and a radius, so the geometry needs no layout.

**1. The mapping walk.** It covers cap exceeded, the partial block, clamping and the hand-overs, which no fixture can sweep.

- **The card.** The shape of `fixtures/rewards-account-config.json`: a minimum of 100, one tier at 1,000, a cap of 2,400 at the base level and of 2,998 at the tier (the fixture's 3,000, moved off a multiple of the block so the walk crosses a partial-block cap), and earning blocks of 5.
- **The walk.** Spend from −50 (a refund-heavy period) to 3,200 in $1 steps.
- **The inputs.** For each step, build the row the server would send, from rules written in the test independently of the projection: `minimum_spend` 100 until 1,000 and 1,000 from it (the level in force); `active_spending_tier_id` the tier's from 1,000; `minimum_spend_met` from 100; `has_next_spending_tier` and `next_spending_tier_threshold` 1,000 below 1,000; `maximum_spend` 2,400 below the minimum and 2,998 from it; counted spend in whole blocks; `maximum_spend_exceeded` once the headroom is under one block.
- **The assertions.**
  - `h`, `v`, the sun's x and y and the gap are finite and within range at every step.
  - Below 100: `h` is spend / 100, clamped at 0; `v` is 0; the marker is at `h`; the sun's x is `h` clamped to 0.07…0.85; the gap is `1 − h`.
  - From 100 to 1,000: `h` is 1, `v` is `0.5 × (spend − 100) / 900`, there is no marker, the sun's x is 0.85 and the gap is 0.
  - From 1,000 until capped: `v` is `0.5 + 0.5 × clamp((counted − 1,000) / 1,998)`.
  - `v` is exactly 1 exactly when the action is `capReached`: from counted 2,995 of 2,998, a partial block, to the end of the walk past the cap.
  - Between consecutive steps no value decreases. There is no jump: `v` is 0 on both sides of the minimum, and within one step of 0.5 on both sides of the tier.

**2. The edge cases.** One table-driven test beside the walk; each row is an input the fixture cannot reach, named for the failure it guards.

| Case | Input | Expected |
| --- | --- | --- |
| Clamping: refunds | Minimum 500, spend −40 | `h` 0, `v` 0, marker at 0 |
| Clamping: counted spend lags raw at the minimum | Minimum 503, blocks of 10, cap 1,000: raw 504, counted 500 | `v` 0, never below |
| Clamping: amounts that are not finite | `minimumAmount` not a number or negative; a basis spend that is not a number | Treated as 0; no output is NaN |
| Clamping: a cap at or below the foot | Minimum 500, cap 400: raw 600, counted 300 | `v` 0.75, measured from 0 |
| Cap exceeded | Cap 2,000, spend 2,150, counted 2,000, `capReached` | `h` 1, `v` 1, the sun's y at `−1.05 r`; the same for any spend beyond |
| Partial-block cap | Cap 1,000, blocks of 5: raw 996, counted 995, exceeded flag | `v` 1; the basis stays 995 of 1,000 |
| No minimum, cap only | Cap 1,000; counted 0, then 250 | `h` 1, no marker, `v` 0, then 0.25 |
| No minimum, tier only | One tier at 400; spend 315.50 | `v` 0.394, measured from 0 |
| Minimum, tier and cap | Minimum 100, tier 200, cap 500: spend 150 (`nextTier`); counted 200; counted 350; counted 500 | `v` 0.25; 0.5; 0.75; 1 |
| A further tier | Minimum 100, tiers 500 and 1,000: spend 300, then 750 (the first tier reached), then `topTier` at 1,200 | `v` 0.25; 0.5; 0.5 |
| A tier at the minimum | Minimum 300, one tier at 300: `topTier`; then a cap of 1,000 with counted 650 | `v` 0.5; then 0.75 |
| Monthly minimum, then a cap | No card minimum, monthly minimum 300: month 250 of 300; then the month met, cap 1,000, counted 650 | `h` 0.833, `v` 0, marker; then `h` 1 and `v` 0.65, measured from the card's minimum (0), never the month's |
| The sun's geometry | `h` 0.03, 0.5, 0.9, 1; then `v` 0, 0.5, 1 at `h` 1, with a horizon at 42 and `r` 8 | x 0.07, 0.5, 0.85, 0.85; y 42.6, 42.6, 39.4, 32.8 (resting); then 32.8, 12.2, −8.4 |
| Failed | `qualificationFailed` | No sun, no marker, `h` 0, `v` 0, the ridges apart |
| No target | `noTarget`, also with `rewardsLocked` | `h` 1, `v` 0, no marker, the sun resting, the ridges apart, an even light |

Do not write tests for the mapping table row by row (E2E reaches every row through the fixture), geometry constants, colour values, font names or view structure. The walk already covers the partial block and a cap that is exceeded; the edge table adds the monthly minimum, failed and no-target cases because they have no walk.

**Existing tests to retarget** (keep their intent and expectations; these are not new tests):

- `testStatusRowsRenderLightDarkAndLargeText` (`apps/ios/HowMuchTests/RewardsReportTests.swift:1422-1506`): render `RewardExposureRow` at `.large`, and the band row at `.accessibility1`. Its OCR expectations stay the same. OCR finding the text in five appearances is the legibility proof.
- The detail sheet snapshots (`:651`, `:680`, `:837`) now render the hero and slip, with unchanged expectations.
- `apps/web/src/lib/rewards-tile.test.ts`: the historical tile still reads the cutoff period's minimum. The meters and stats move into the disclosure but stay in the markup, so its positive and negative assertions stand. Do not weaken them.

### States fixture

Add `fixtures/rewards-exposure-states.json`, a Rewards Tracker export. An import replaces the stored card set, so it includes Travel Card. Every card is bound to `acct-credit`. The demo ledger's Travel Card spend is $26.40 in March (11 Mar, red flag), $488.90 in April (12 Apr, red) and $315.50 in May (4 May $228.90 blue, 13 May $86.60 red). As of **24 May 2026**, a calendar card has 8 days left.

Expected values are worked out by hand from those numbers. Before taking screenshots, confirm each one against `GET /api/reports/rewards?plan_id=local-plan&to=2026-05-24`. If the server disagrees, the server is right: change the card's thresholds and record why. Never quietly change an expectation. No card configures a tier at 0: beside a minimum it would sort first and make the server treat the minimum as met.

| Card | Configuration | Expected headline · deadline | Expected basis | Picture |
| --- | --- | --- | --- | --- |
| A Exposure Below | Cashback, calendar, minimum 500, rate 1 | $184.50 to minimum · 8 days left | $315.50 / $500.00 | Gate, `h` 0.631: the marker at 0.631 W with the half-disc sun riding it; spend line 63% of the way up; amber disc; rings at their smallest |
| B Exposure Urgent | Cashback, billing day 26, minimum 500 | $184.50 to minimum · 2 days left, urgent | $315.50 / $500.00 | Identical art to A. Confirm the period is 26 Apr to 25 May. Deadline in `UrgentInk`. |
| C Travel Card | As today: miles, minimum 200, Dining 4, Online 3 | Minimum met · Resets in 8 days | $315.50 / $200.00 · 1,033 miles earned | Rest on the miles sky (night in dark mode; in light mode the whole band gold at 0.76, the contrail all but hidden): no marker, merged, the sun resting in its column, 1 ring |
| D Exposure Headroom | Cashback, maximum 1,000, no minimum | $684.50 left before bonus cap · 8 days left | $315.50 / $1,000.00 | Climb from 0, fully lit from the start: `v` 0.316 (no minimum, so measured from 0), rings at 22% |
| E Exposure Tier | Miles, no minimum, one tier at 400 | $84.50 to next tier · 8 days left | $315.50 / $400.00 | Climb: `v` 0.394 (half of 315.50 / 400), rings at 23% |
| F Exposure Capped | Cashback, maximum 300, rate 1 | Bonus cap reached · Resets in 8 days | $300.00 / $300.00 · … · $15.50 beyond cap | Capped: `v` 1, the sun off the top, the pour from the top edge; beyond the cap looks the same |
| G Exposure Block | Cashback, maximum 314, earning block 5 | Bonus cap reached · Resets in 8 days | $310.00 / $314.00 · … · $1.50 beyond cap | Capped, with a raw figure under 100%. Confirm `counted_spend` 310 and `maximum_spend_exceeded`. |
| H Exposure Top | Cashback, minimum 300, one tier at 300 | Highest tier active · Resets in 8 days | $315.50 spent · … | Rest at halfway: `v` 0.5, rings at 26% |
| I Exposure Open | Cashback, no minimum or cap | No cap · Resets in 8 days | $315.50 spent · … | Calm: even, softer light; the sun resting; 1 ring |
| J Exposure Failed | Miles, 3-month period from 1 Mar, monthly minimum 100 | March minimum missed · Resets in 8 days | $830.80 spent · … | Monochrome and overcast, no sun, no marker, ridges apart, veiled throughout |
| K Exposure Monthly | Cashback, 3-month period from 1 Apr, monthly minimum 400 | $84.50 to monthly minimum · 8 days left | $315.50 / $400.00 | Gate, `h` 0.789, spend line 79% of the way up |
| L Exposure Locked | Cashback, 3-month period from 1 Apr, monthly minimum 300 | No cap · Resets in 38 days, slip "Rewards unlock after 30 Jun" | $315.50 spent · … | Calm. Confirm the month list and status. |
| M Exposure Category | Miles, minimum 200, Online capped at 200 | Minimum met · Resets in 8 days, slip "Online over cap" | $315.50 / $200.00 · … | Rest, `v` 0 |
| N A long name, such as "Exposure Long Name Preferred Platinum Rewards" | As A | As A, name on two lines | As A | As A, ridges lower; the marker crosses the name |
| O Exposure Step | Cashback, minimum 200, one tier at 400 | $84.50 to next tier · 8 days left | $315.50 / $400.00 | Climb from the minimum: `v` 0.289 (half of 115.50 / 200), rings at 21%; merged and fully lit, because a met minimum keeps the light |
| P Exposure Journey | Cashback, minimum 100, one tier at 200, maximum 500 at both levels | $184.50 left before bonus cap · 8 days left | $315.50 / $500.00 | Climb past halfway: `v` 0.693 (0.5 + 0.5 × 115.50 / 300; the tier at 200 is reached), rings at 31% |

The performance variant (`fixtures/rewards-exposure-states-30.json`) holds each card twice.

### iOS recipe: `.cursor/skills/verify-howmuch/features/ios-rewards.md`

**First, fix stale lines.** The recipe predates the filled-rows board. The board has no date-range chip and no Group chip, because groups live in Range Report. The empty state reads "No Reward Cards", not "No reward cards in this range.". "Tap the rewards bar" becomes "tap the rewards row".

**Then add these sub-features:** `ios-rewards-exposure-states`, `ios-rewards-exposure-sheet`, `ios-rewards-exposure-motion`, `ios-rewards-exposure-register` and `ios-rewards-exposure-accessibility`. Steps:

1. **Set-up** (not under test). Launch with `control-howmuch launch` and pass `doctor`. Import the states fixture through web **Settings → Rewards import**. Sign the Simulator in, and enable Simulator accessibility as `apps/ios/AGENTS.md` describes.
2. **States.** Rewards → Featured menu → **All Cards**. Today menu → **Choose Date…** → 24 May 2026 → **Done**. For each card, screenshot the row and dump its accessibility element. Compare the text and value with the fixture table and the state tables. Measure each marker's x against `h × W` and each sun's centre against the sun's path for its pose, and compare A and B (failure mode 5). Sample A's sky and ground either side of the marker (failure mode 7).
3. **Sheet.** Open A: the marker at 0.631 W with the half-disc sun on it, the ridges apart, the label "$500.00 minimum" and the minimum tick at the sun's column. Then open K, D (fully lit, the sun 0.32 up its column), P (past halfway), F (the sun gone off the top, the glow from the top edge) and J (monochrome). Screenshot each hero.
4. **Appearances.** Screenshot A, B, C, F, I, J and N again:
   - dark: `xcrun simctl ui "$UDID" appearance dark`;
   - AX3: `xcrun simctl ui "$UDID" content_size accessibility-extra-extra-extra-large`, which must give paper rows with bands;
   - Increase Contrast: Settings → Accessibility → Display & Text Size, or `simctl ui` where the installed Xcode supports it.
5. **Motion** (record with `xcrun simctl io "$UDID" recordVideo`). Relaunch and open Rewards: each gate card's lit edge sweeps right with its sun riding the marker along the horizon, each card past a minimum sweeps and then rises, and each card without a minimum shows its sun climbing straight up its column, once, staggered. No sun moves diagonally. Scroll to the end and back: no replay.
6. **Register glide and persisted write** (record). This step uses a fresh stack with `fixtures/rewards-tracker-export.json`, so the register shows one row. Open Accounts → Travel Card. Today's month has no demo spend, so the row reads "$200.00 to minimum · N days left": mostly unlit (blue in light mode), the half-disc sun at the left. Add a transaction: $100.00, payee "Exposure check", today. Back in the register, the marker and the sun glide to half the print's width (`h` 0.5), the lit edge follows, the spend line lifts halfway to the target horizon, and the row reads "$100.00 to minimum". Persisted proof:
   - `control-howmuch http GET "/v1/plans/local-plan/transactions"` lists the transaction;
   - `control-howmuch http GET "/api/reports/rewards?plan_id=local-plan&account_ids=acct-credit"` shows `total_spend` 100 against `minimum_spend` 200.
7. **Cap and tier changes** (record, states fixture, as of today).
   - D reads "$1,000.00 left before bonus cap" with its sun resting, F reads "$300.00 left before bonus cap", O reads "$200.00 to minimum" and P reads "$100.00 to minimum".
   - Add $320.00 to Travel Card. When the board refreshes:
     - F and G glide to capped once: each sun climbs straight off the top and the glow grows;
     - O's lit edge sweeps to the right edge, its spend line meets the target horizon, its sun lifts clear and climbs to `v` 0.3 in the same glide, and it reads "$80.00 to next tier";
     - P sweeps, lifts and climbs past halfway in one glide, to `v` 0.7, and reads "$180.00 left before bonus cap";
     - other cards glide; none reach capped except F and G.
   - Add $90.00 more. O reaches its tier and reads "Highest tier active": its sun glides up to halfway and stays there. No crossfade, because nothing falls.
   - Reopen the board: no replay.
8. **Reduce Motion** (record). Turn on Settings → Accessibility → Motion → Reduce Motion and repeat step 6 with $50.00. The marker jumps with no glide, and step 7's changes do not animate.
9. **A falling change** (record). Today menu → **Choose Date…** → 31 May 2026, then step to 1 Jun 2026. K's new month starts at `h` 0 with a crossfade, never a backward glide.
10. **Accessibility dump.** One element per card, labelled with the card name, valued with the table string, and nothing for the art.
11. **Performance.** With the 30-card fixture, fling the board with Instruments' Animation Hitches template running. Record the simulator's limits, and leave the device check to the owner.

**Proof.** `RECORD.md` holds:

- the revision: `git rev-parse HEAD`, plus a diff hash if the tree is dirty;
- the fixture checksum, the Simulator model and the iOS version;
- the exact commands and steps, expected against observed.

Also save:

- screenshots named `{card}-{appearance}.png` and `hero-{card}.png`;
- recordings `load.mp4`, `register-glide.mp4`, `cap-and-tiers.mp4`, `reduce-motion.mp4` and `month-change.mp4`;
- accessibility dumps `ax-board.txt` and `ax-register.txt`;
- the marker and sun measurements and pixel samples, with the GET JSON.

A screenshot alone does not prove step 6: the GET output does.

### Web recipe: `.cursor/skills/verify-howmuch/features/rewards.md`

- **Open filled.** The face's headline now reads "Minimum met · Resets in 8 days" with the basis line. "Full-period minimum met" moves inside **Targets, periods and tiers**.
- **New `rewards-exposure-states`.** Import the states fixture through Settings → Rewards import and open `/rewards?to=2026-05-24`. For each card:
  - check the slip text and the `data-stage` and `data-mono` attributes against the fixture table;
  - check the marker line's x against `h × W` and the sun's centre against its pose.
  Do it at 1440 × 900 (3:2 face) and 390 × 844 (strip). Screenshot Dusk Ridge light and dark, plus one other look in both modes. Within a mode the faces must be pixel-identical across looks; only the chrome differs. Between modes they differ by design: daytime faces in light, the prints in dark.
- **Featured.** On the desktop face a featured card's caps line ends in the word "Featured". The phone strip shows no mark.
- **Motion.** Step the as-of date with **Next day** and record a Playwright video: the marker and the lit edge glide across on gate cards, the suns climb straight up on climb cards (after a sweep where the card has a minimum), and the figures settle without counting. Under `page.emulateMedia({ reducedMotion: "reduce" })`, the first frame already shows the final `--rw-h` and `--rw-v`.
- **Proof** goes in `.amp/in/artifacts/rewards-exposure/web/`, with the same `RECORD.md` fields.

## Open questions for the owner

The owner's 7 Oct review answered version 1's questions on the sun's horizontal meaning (progress, not time), the pace line (gone) and the Featured mark (see The Featured mark). The follow-up on light mode settled day faces: faces follow the appearance. The owner's answers to the version 2 lab settled the stage split (two journeys: across for the minimum, up for tiers and the cap), the jump at the minimum (gone: the cap climb starts at the minimum), tiers (the sun rises halfway and stays there), the light-mode marker (warm white) and ground (lighter greens with dark ink).

1. **Ridge reading.** Level, where the gap shrinks with spend (specified)? Or literal, cumulative spend by day running on horizontally, which needs a Worker change and puts time back into the art?
2. **Calm cards.** Cards with no target sit in an even, softer light, with the sun at rest and no marker. Cards whose rewards are locked or withheld look the same, and only the slip says so. Should those be dimmer?
3. **Period track.** Add the optional thin labelled period track under the sheet's hero, or leave time to the deadline text and the Periods section?
4. **What the strip leaves out.** It drops today's chevron and does not take the web face's issuer and type caps line ("DBS · Miles"), to stay at today's height. Want either back? The caps line costs about 13pt per row; the sun's column already leaves room for the chevron.
5. **Register.** A paper row with a thumbnail print (specified), or the full strip, as on the Rewards tab?
6. **Earned.** The strip keeps the earned amount inside the basis line, as today. The web face shows it large in the corner. Should it be large on the phone too? It would sit on the ground under the sun's column, clear of the sun at any height.
7. **Partial-block cap.** Leave the row as specified (capped, the sun off the top with the raw figure, and the sheet explains blocks)? Or add "Within one block of the cap" to the row?
8. **Failed look.** An overcast monochrome print with no sun (specified, which keeps text contrast)? Or the concept's milky fog, which needs different inks on fogged night skies?
9. **Miles against cashback in light mode.** Miles is a higher, cooler blue with a faint two-line contrail, and cashback a warmer haze (specified). The contrail shows only on the unlit sky, so in practice only in the minimum journey, and never crosses the name, but it is still a line across the sky after the dotted pace line was dropped. Keep it, or tell the two apart by the blue alone?
10. **Fonts on iOS.** Bundle Instrument Serif and IBM Plex for the card only now (about 1.3 MB) and decide on app-wide use later?
11. **iPad.** Cap the rows at 640pt (specified), or lay strips out in a two-column grid at regular width?
12. **Zoom from row to sheet.** Try `matchedTransitionSource` with `.navigationTransition(.zoom)` on a device, and keep it only if the sheet keeps its content-height detent? Or stay with the plain sheet?
13. **An existing VoiceOver repeat.** Cards with no basis (Highest tier active, No cap, failed) speak the earned amount twice. Fix it in this change, with a failing test first, or leave it?
14. **More than one tier.** The projection carries one reached-tier threshold, so on a card with several tiers the sun stays at halfway between the first tier and the cap (specified), and never sinks. Or spread the lower half of the climb across the tiers, which means carrying every tier threshold in the projection?
15. **The strip's sun.** Settled on 10 Oct 2026 by the phone cut: a 10pt half-sun on the horizon, the sky band 34pt with the icon's two slopes, no hairline and one soft glow on the phone layouts.
