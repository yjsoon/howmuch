# Rewards Exposure card

Implementation spec, version 2 ("Sun Arc v2"). It replaces the iOS Rewards progress fill (`RewardFilledRow`) with the Exposure card, and moves the web board's face onto the same rules, so a card reads the same on both platforms. Version 2 follows the owner's review of the Sun Arc lab page on 7 Oct 2026. This slice has no code. The Swift and TypeScript below are sketches, unverified because this machine has no Xcode.

Read it with [the agreed filled-rows spec](../plans/rewards-filled-rows-agreed-spec.md). That spec still owns what a row says: precedence, wording, rounding, deadlines, ordering and the summary line. This document owns how the card looks and moves. Paths are relative to the repository root. iOS paths without a prefix are under `apps/ios/HowMuch/`.

## Changes from version 1

| Version 1 | Version 2 | Why |
| --- | --- | --- |
| The sun's position across the sky was time elapsed in the period | Across is progress only: the exposure scalar `e`. Time lives in the deadline text. | Owner: the path "starts from the left (start of the earning period) and moves to the right as spending increases". One horizontal meaning. |
| Dotted pace line and day ticks in the art | Removed from every layout | Owner: "not a fan of the dotted line across the screen" |
| Sun height was `fill` | The sun rides one arc driven by `e`: partly below the horizon until the minimum, clear at the minimum, high at the cap | Owner: the sun "rises above the horizon fully once spend is reached" |
| Exposure followed the tone | The art is lit from the left up to a progress marker and underexposed to its right | Owner: "at a glance even when squinting we can see it's say 20% of the way there" |
| No marker | A faint vertical hairline at `e`, from near the top to the bottom edge | Owner: "Like the icon there should be a faint vertical line" |
| Two fixed brand ridges | A ridge pair: the target horizon above, the spend horizon below; the gap is what is left to the minimum | Owner: keep the Spend Ridge idea, the lower line "never meeting the top line" until the minimum is met |
| A terminal cap set the sun and dimmed the sky | A cap is the brightest state: the whole band lit | Owner: "once it's too high off, it's full (and the entire bar is quite bright)". This **reverses** version 1; see Capped is done. |
| Projection gained `window` and `elapsed` | No projection additions | They only placed the sun in time |
| Featured mark "✦" | The word "Featured", only where a caps line already exists | Owner did not recognise the mark |
| Strip about 116pt | About 104pt, today's row height | Keep the list as dense as today |

## Goal and non-goals

**Goal.** Each card becomes a small photograph that spend exposes from left to right: a sky, a pair of ridges and a sun.

- **One horizontal meaning.** Across the card is progress, the exposure scalar `e` from 0 to 1. Never time.
- **The light is the read.** The art is lit from the left edge up to the progress marker and underexposed to its right, with a short soft falloff, so a squint reads "about a fifth of the way".
- **The marker is the definitive point.** A faint vertical hairline at `e`, through the sun's centre, from near the top to the bottom edge, like the line in the brand mark.
- **The sun is the figurehead.** It rides one arc: a sliver peeking over the horizon on the left at the start, fully clear of the horizon when the minimum is met, high at the right when the bonus cap is reached.
- **The ridge pair tells what is left.** The upper line is the target horizon. The lower line is the spend horizon, nearly level across the full width. The gap between them is what is left to the minimum. They meet when the minimum is met and rise together from there.
- **States.** Capped is fully lit: done, not failed. Failed is monochrome with no sun. A card with nothing to chase sits calm, with no marker.
- Every word and figure the current row shows stays, unchanged, from `RewardRowText`. The picture replaces the coloured fill and nothing else.

**Non-goals.**

- No server or calculator change, and no new projection fields. The picture reads `action` and `fill`, which the projection already has.
- No time inside the art: no pace line, no day ticks, no sun that follows the calendar.
- No change to precedence, wording, rounding, deadlines, ordering, the summary line or the VoiceOver strings.
- No Apple Wallet look: no chip, no masked number, no network mark, no ID-1 ratio, no stacked pile of cards, no flip.
- No count-up or rolling digits, and no idle animation.
- No widget or Live Activity in this slice. The paper row below is the likely widget layout later.
- No iOS restyle to Dusk Ridge chrome (plum and warm paper). Faces are brand prints and look the same in every look and mode, on both platforms. The chrome around them stays iOS's own.
- No daily spend series. The ridge pair borrows the Spend Ridge concept's two lines, not its data. The literal reading (cumulative spend by day) is phase two; see The ridge pair.
- No per-month film strip (the "Contact Strip" concept). It stays a later candidate for the sheet's Qualification section.
- The detail sheet keeps its sections (Targets, Tiers, Qualification months, Categories, Periods). Only its header changes.

## What the card communicates

### The exposure scalar

`e` is one number from 0 to 1 that drives everything in the art. It has two stages, split at the **sunrise point**, 0.6:

- **Stage 1, the gate.** Toward a minimum or a monthly minimum: `e = 0.6 × fill`. The sun is partly below the horizon and the ridge lines are apart.
- **Stage 2, the headroom.** Toward a next tier or the bonus cap: `e = 0.6 + 0.4 × fill`. The sun is clear and climbing, and the ridges are merged. A card with no minimum starts here at 0.6.
- **Full.** The bonus cap is reached: `e = 1`, and the whole band is lit.
- **Calm.** Nothing to chase (minimum met with no cap, highest tier, no cap at all): the sun rests at the sunrise point, the band is evenly lit, and there is no marker.

The width of the card is the whole journey: the period's start on the left, the minimum at 0.6, the cap at the right edge. The ridge gap is the other read: in stage 1 it is exactly the share of the minimum still to spend. So a card at $250 of a $500 minimum shows the marker at 0.3 of the width and the spend line halfway up to the target horizon.

`e` is a picture coordinate, not a figure. It is never printed, spoken or turned into words. The basis line and the spoken percentage stay the projection's basis, unchanged.

### The mapping, checked against the projection

`fill` always comes from the projection's single basis (`Support/RewardRowProjection.swift:172`), or the projection's own pinned value; the mapping never computes a figure of its own. Actions in the projection's precedence order (`:215-275`):

| # | Action | Basis and `fill` | Stage | `e` | Marker |
| --- | --- | --- | --- | --- | --- |
| 1 | `qualificationFailed` | None; `fill` nil | Failed | none | No |
| 2 | `monthlyMinimum` | Month spend / month minimum | Gate | 0.6 × fill | Yes |
| 3 | `minimum` | Raw spend / minimum | Gate | 0.6 × fill | Yes |
| 4 | `nextTier` | Raw spend / next threshold | Headroom | 0.6 + 0.4 × fill | Yes |
| 5 | `capHeadroom` | Counted spend / cap | Headroom | 0.6 + 0.4 × fill | Yes |
| 6 | `capReached`, terminal or not | min(counted, cap) / cap, but `fill` pinned to 1 (`:255`) | Full | 1 | Yes, at the right end |
| 7 | `topTier` | None; `fill` pinned to 1 | Calm | 0.6, fixed | No |
| 8 | `minimumMet` | Spend / minimum, `fill` 1 | Calm | 0.6, fixed | No |
| 9 | `noTarget` | None; `fill` nil | Calm | 0.6, fixed | No |
| 10 | `range` | None | No picture | | |

What the check found:

- **Next tier is stage 2, not stage 1.** The brief put the next tier in stage 1. But `nextTier` fires only after the minimum branch has passed (`:224-236`: spend has reached the card's minimum, or there is none). In stage 1, a tiered card would sink back below the horizon, and its ridge lines would part again, on the very day its minimum is met. That contradicts the owner's "the two meet when min spend is met, and rise together from there". The repository's own `fixtures/rewards-account-config.json` has exactly that shape (minimum 100, a tier at 1,000). In stage 2 the tier rides the same rule as "cards with no minimum start stage 2 at 0.6". See open question 1.
- **Meeting the minimum steps forward.** A card with a minimum and a cap jumps from just under 0.6 to `0.6 + 0.4 × counted / cap` on the day the minimum is met, because stage 2 reads counted spend against the cap from zero. It never steps back.
- **A target change can step back.** When a tier is reached, the next target (a higher tier, the cap, or nothing) can sit further left than the old one did: `e` falls from near 1 to, say, 0.73. That is honest (the journey got longer), and the face crossfades instead of gliding backwards (see Motion). Within one target, `e` only moves back on a refund.
- **Minimum met is calm.** The brief says "minimum met is 0.6". `minimumMet` keeps `e = 0.6` for the sun and the merged ridges, but has no marker and no dim right side, because a card with no cap has no stage-2 target. A dim 40% would promise a target that does not exist.
- **The partial-block cap is full.** `capReached` pins `fill` to 1 while the basis shows 995 of 1,000. The picture follows the pinned value; the figure stays raw.
- **Tone changes ink, not geometry.** The `earning` to `neutral` downgrade for an unqualified card (`:278-280`) leaves `e` alone. Only stage 1's amber sun core follows the needs-minimum state.
- **Exceptions are words.** Locked rewards ("Rewards unlock after 31 Oct") and withheld rewards ("Minimum not yet met") leave the picture as the action draws it. See open question 3.
- **No as-of date** changes nothing in the picture, because nothing in it is time. Only the deadline text drops.

### Channels

| Channel | Source | Rule |
| --- | --- | --- |
| Marker | `e` | Hairline at `x(e)`. Gate, headroom and full only. |
| Light | `e` | Lit left of the marker, falloff over 8% of the width starting at the marker, underexposed to the right. Calm: evenly lit. Failed: underexposed everywhere. |
| Bloom | `e` | A warm wash over the whole sky, fading in from `e` 0.96 to 1 |
| Sun | `e` | Rides the arc. None when failed. |
| Ridge gap | Stage-1 fill | `(1 − fill)` of the full gap in stage 1; closed in every other stage, open at rest when failed |
| Merged ridge lift | Stage-2 progress | Rises gently with `(e − 0.6) / 0.4` |
| Rings | `e` | None in stage 1. From sunrise, one ring per tenth: 1 at 0.6, 2 at 0.7, 3 at 0.8, 4 at 0.9. One when calm. |
| Sun core | Stage | Amber `SunCoreUnder` in stage 1 (needs-minimum keeps its amber); `SunCore` otherwise |
| Sky | `rewardType` | Miles: night sky. Cashback: day sky. |
| Monochrome | `tone == .failed` | Saturation 0.15 over the whole face |

### State table: the picture

Examples are the `RewardRowProjectionTests` fixtures in `apps/ios/HowMuchTests/RewardsReportTests.swift`. They use SGD, as of 23 Sep 2026, with a 1 to 30 Sep period unless noted.

| # | State | Trigger in the projection | `e` and marker | Sun and rings | Ridges, light and colours |
| --- | --- | --- | --- | --- | --- |
| 1 | Below minimum | `.minimum`, tone `needsMinimum` | 0.524 (698 of 800) | Partly below the horizon, its centre 0.8 r above it; amber core; no rings | Spend line 87% of the way up to the target horizon. Lit to the marker. |
| 2 | Monthly minimum behind | `.monthlyMinimum`, `needsMinimum` | 0.5 (250 of 300) | Partly below, amber | Spend line 83% of the way up |
| 3 | Next tier | `.nextTier`, `earning` | 0.935 (1,340 of 1,600) | Clear, high; 4 rings | Merged, lifted 0.84 of the lift |
| 4 | Intermediate cap | `.nextTier` with exception `tierCapReached` | As 3. Web R1 marks it complete today; that is a bug. | As 3 | As 3; exception in the slip |
| 5 | Cap headroom | `.capHeadroom`, `earning` | 0.86 (650 of 1,000 counted) | Clear; 3 rings | Merged, lifted 0.65 |
| 6 | Minimum met | `.minimumMet`, `earning` | Calm, no marker | Resting just clear at the sunrise point; 1 ring | Merged, no lift; evenly lit |
| 7 | Top tier | `.topTier`, `earning`, no basis | Calm | As 6 | As 6 |
| 8 | Cap reached, not terminal | `.capReached(terminal: false)`, `earning` | 1, marker at the right end | High; 4 rings | Merged at full lift; whole band lit with bloom. Rare: a next tier exists at or below spend. |
| 9 | Terminal cap | `.capReached(terminal: true)`, `complete` | 1 | High; 4 rings | As 8. Headline in foot ink. |
| 10 | Partial-block cap | As 9, basis 995 of 1,000 | 1. The picture follows the pinned fill, the figure stays raw. | As 9 | As 9 |
| 11 | Failed | `.qualificationFailed`, `failed` | None | No sun | Ridges apart at rest; underexposed everywhere; monochrome. Headline in `FailedInk` #FFABAE. |
| 12 | No target | `.noTarget`, `neutral`, no fill | Calm | As 6 | As 6 |
| 13 | Rewards locked or withheld | `.noTarget` with `rewardsLocked` or `minimumNotMet` | Calm | As 6 | As 6; exception in the slip |
| 14 | Neutral with a target | A target action whose `earning` tone was downgraded to `neutral` | By its action | By its action | By its action; only the ink changes |
| 15 | Range | `.range` | No picture | | Paper row without a print |
| 16 | No as-of date | Any; `deadline` is nil | As its state | As its state | As its state |

An urgent deadline is not a picture state. Any `.ends` deadline within 3 days sets the deadline text in SemiBold `UrgentInk` (#FFD98C) on the ridge, or the tone ink on paper, exactly as today.

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
| 10 | `:1153` spend 996, counted 995, cap 1,000 | Bonus cap reached · Resets in 8 days; $995.00 / $1,000.00 · $0.00 earned | The spoken figure is 995 of 1,000, from the basis, not from the lit band |
| 11 | `:1199` July 200 of 300 failed; period 1 Jul to 30 Sep | July minimum missed · Resets in 8 days; $0.00 spent · $0.00 earned | July minimum missed. $0.00 spent · $0.00 earned. Resets in 8 days, period ends 30 Sep. $0.00 earned |
| 12 | `:1163` spend 420, earned 8.40 | No cap · Resets in 8 days; $420.00 spent · $8.40 earned | No cap. $420.00 spent · $8.40 earned. Resets in 8 days, period ends 30 Sep. $8.40 earned |
| 13 | `:1246` September met, October pending; period 1 Sep to 31 Oct; spend 900 | No cap · Resets in 39 days; $900.00 spent · $0.00 earned; slip "Rewards unlock after 31 Oct" | No cap. $900.00 spent · $0.00 earned. Resets in 39 days, period ends 31 Oct. $0.00 earned. Rewards unlock after 31 Oct |
| 14 | No dedicated test | The target's headline, plus "Rewards unlock after …" or "Minimum not yet met" | As the text |
| 15 | `:1365` spend 1,000, earned 40 | **$40.00** earned; $1,000.00 spent | $40.00 earned. $1,000.00 spent |
| 16 | `:1357` no as-of date | As its state, with no deadline | As its state, without the deadline clause |

### Capped is done

Version 1 set the sun behind the ridge at a terminal cap and dimmed the sky, and the lab page drew it that way. The owner described the opposite as if it were already there: "once it's too high off, it's full (and the entire bar is quite bright)". Version 2 follows the words, so this **reverses** version 1:

- At `e = 1` the sun is high at the right, all four rings show, the bloom washes the whole sky, and the crest strokes brighten. There is no dim overlay and no afterglow.
- Capped still reads as done, not failed. The band is bright and still, the headline says "Bonus cap reached", and the iOS `.complete` ink moves from red to dusk. Failed keeps the opposite look: monochrome, no sun, red headline.
- A terminal and a non-terminal cap look the same. Only the words differ.

### The partial-block cap

The server sets `maximum_spend_exceeded` once the headroom is less than one earning block. So a card can be "Bonus cap reached" at $995.00 of $1,000.00 (state 10). The decision:

- The picture follows the **action**: fully lit at `e = 1`, because the server says the bonus is spent and the projection pins `fill` to 1.
- The figure stays **raw**: "$995.00 / $1,000.00". It is never rounded up to look full.
- The sheet's existing Cap target row already carries the block caption: "Counts spend in whole earning blocks, so the room left can differ by up to one block." Nothing new is added to the board row. Whether to add a row hint is an open question.

### The Featured mark

The "✦" after "DBS · MILES" on the web face and in the lab is the Featured flag. The owner did not recognise it. Decision: **drop it from the compact row and show the word only in the expanded form.**

- The board opens on **Featured only** whenever any card is featured (`Views/RewardsView.swift:130`), so on the default view a per-row mark would sit on every row and say nothing. The Featured control above the list already names the filter.
- The compact strip has no caps line, so a pill would cost a line, about 13pt per row.
- Where a caps line already exists, "Featured" is a plain word in it: "DBS · Miles · Featured". That is the iOS sheet slip and the web's desktop 3:2 face. No glyph, no pill.

## Geometry

### Layouts

| Layout | Used for | Size at the default text size (`.large`) |
| --- | --- | --- |
| **Strip** | Rewards board rows | Full row width, about 104pt tall. The row is the frame. |
| **Paper row with print** | Account register strip | About 96pt, with a 90 × 60pt print on the trailing side |
| **Paper row with band** | Board and register rows at accessibility text sizes | A 64pt scene band above the text |
| **Paper row, plain** | Range Report "Cards" section | As today, no picture |
| **Hero** | Detail sheet header | A 3:2 print with a 6pt border |

### The scene

Every layout draws the same scene, back to front:

1. sky, horizon warmth, then the bloom (near `e = 1` only);
2. halo, rings and sun disc;
3. upper ridge (target horizon) with its crest stroke;
4. lower ridge (spend horizon) with its crest stroke, or one merged crest;
5. the foot scrim (strip only);
6. the veil (the underexposure right of the marker);
7. the marker.

Text is never inside the scene. Each layout sets:

| Layout | Lane margin `m` | Target horizon `U(x)` | Spend floor `Fl(x)` | Stage-2 lift | Zenith (sun centre at `e = 1`) | `r` | Ring spread σ |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Strip | r + 4pt | `N + 13pt`, ±1.5pt, to 0.52 W, then rising smoothly to `N − 3pt` at the right edge | `F − 5pt`, ±1pt | 4pt | 0.06 h + r + 2pt | 6pt | 0.8 |
| Print, 90 × 60 | r + 3pt | Brand back ridge | 0.82 h, ±0.01 h | 0.04 h | 0.16 h | 4pt | 0.6 |
| Band, 64pt | r + 6pt | 0.52 h to 0.52 W, rising to 0.36 h at the right edge | 0.80 h | 3pt | 12pt | 6pt | 0.7 |
| Hero | r + 8pt | Brand back ridge: 0.665 h at the left, 0.42 h at the right | 0.80 h, ±0.01 h | 0.04 h | 0.14 h | 0.045 W | 1.6 |
| Web face, desktop 3:2 | As Hero | As Hero | As Hero | As Hero | As Hero | 4.5% of the width (shipped) | Shipped bands |
| Web strip, phones | As Strip | | | | | | |

`N` is the bottom of the name's line box and `F` the top of the headline, both measured in the row. So long names and large text move the ridges rather than overlap them.

**Brand ridge.** Use the web SVG paths verbatim (`apps/web/src/pages/Rewards.tsx:697-702`, viewBox `0 400 1024 624`, stretched into the bottom 58% of the frame). A SwiftUI `Path` cannot be asked for y at a given x, so sample the back crest once into a static 65-point table and interpolate. The web port uses the same table.

### The arc

The sun travels the path the pace line used to draw: from the left horizon, rising as it moves right. It hugs the horizon through stage 1 and climbs in stage 2.

- `x(e) = m + e × (W − 2m)`. The disc never clips at either end.
- The horizon under the sun: `h(e) = U(x(e)) − lift(e)`, where `lift(e)` is 0 in stage 1 and `L × (e − 0.6) / 0.4` in stage 2 (`L` is the layout's lift).
- **Stage 1:** `y = h + 0.6r − (e / 0.6) × 1.6r`. At `e = 0` only the top 0.4 r of the disc breaks the horizon: a sliver of brightness on the left. At `e = 0.6` the disc's bottom sits on the horizon: fully clear.
- **Stage 2:** with `u = (e − 0.6) / 0.4`, `y = (h − r) + (Z − (h − r)) × (1 − (1 − u)²)`. It climbs steeply at first and flattens towards the zenith `Z`, like a sun's path.
- **Calm:** the stage-2 pose at `u = 0`, the sunrise point. **Failed:** no sun.

The y axis points down. On the strip, while the sun is still under the name column (x up to 0.5 W, so `e` up to 0.5), its centre rises at most 0.73 r above the horizon. The disc's top then stays at least 1pt below the name's line box, which is why the strip's target horizon sits 13pt (never less than 11.5pt) below the name there.

### The light

The art is lit from the left edge to the marker and underexposed to its right. This is the primary progress read; the sun is the figurehead.

- **Veil strength.** `v(x) = smoothstep(x(e), x(e) + 0.08 W, x) × (1 − b)`, where `b` is the bloom amount below. Full light up to the marker, a soft falloff over 8% of the width, full veil beyond. The falloff starts at the marker, so the sun's disc stays almost fully lit.
- **Veil look.** Dim and desaturated, with a dusk cast taken from the brand's rose-mauve:
  - one full-frame fill with blend mode `.saturation`, colour `VeilGrey` #808080 at alpha 0.5 × `v` (half way to grey);
  - one full-frame fill with blend mode `.multiply`, from white to `VeilDay` #D4CBD4 on day skies or `VeilNight` #8A8496 on night skies, by `v`.
- **Veil limits.** The day veil is deliberately gentle: it is capped so `InkDay` keeps 6.6:1 on the darkest veiled day stop, because a long name can sit on the dim side. The night veil can be darker: it only raises contrast for light inks.
- **Bloom.** `b = smoothstep(0.96, 1, e)`. `Bloom` #FFE3AC at 30% × `b` over the sky (screen blend on night skies), crest strokes to 100%, horizon warmth × 1.5. At `e = 1` there is no veil at all.
- **Calm:** no veil and no bloom: evenly lit. **Failed:** `v = 1` everywhere, plus the face's saturation 0.15.
- **Cost.** Two gradient fills and an optional bloom fill in the same Canvas pass. No offscreen layer, no blur, no second draw of the scene. Blend modes act on what the context has already drawn.
- **Differentiate Without Colour.** The veil darkens as well as desaturates, so the lit edge reads in luminance alone.

### The progress marker

- **Position.** `x(e)`, through the sun's centre. Drawn for gate, headroom and full; hidden when calm or failed. At `e = 1` it stands at the lane's right end.
- **Extent.** From 0.06 h to the bottom edge. It breaks across the visible part of the sun's disc, 1pt clear of the rim, as in the brand mark (`assets/icon/halation-light.svg`), where the scrub line passes behind the sun.
- **Two tones, as in the brand mark.** The mark draws the line warm above the sun (#C9853F at 42%) and pale on the ridge (#F7F5EF at 18%). The card does the same, split at the target horizon:
  - on the sky: `MarkerDay` #94591A at 55% on day skies, `MarkerNight` #FFD98C at 35% on night skies. The mark's #C9853F is only 1.3:1 on the day sky at hairline width, so the day tone uses the glow ink instead.
  - on the ridges: `MarkerRidge` #F7F5EF at 22%.
- **Crisp.** Two device pixels wide (1pt at 2x, 0.67pt at 3x), with its x snapped to the device pixel grid through `displayScale`, so it never smears across three pixels.
- **Faint but findable.** About 2:1 against the day sky, 2.7:1 against the night sky and 1.6 to 2:1 on the ridges.
- **Under text.** It is drawn last in the scene, after the veil, so it stays warm on the dim side. Text sits above it. At a small `e` it passes behind the name and the foot text. Where a glyph meets it, the ink still has at least 5.4:1 against the marker pixel. The OCR snapshot and state N in the fixture prove legibility.

### The ridge pair

The upper line is the **target horizon**, in the brand's ridgeline shape. The lower line is the **spend horizon**: stylised, nearly level, spanning the full width, so it never ends abruptly. The light band of `RidgeBack` green showing between them is what is left to the minimum.

#### Level (specified)

- Upper line: `U(x) − lift(e)`. Fill `RidgeBack`. Crest stroke `TargetCrest`: `Crest` at 40%, 1pt.
- Lower line: `Fl(x) + g × (U(x) − Fl(x)) − lift(e)`, where `g` is the gate fill: `e / 0.6` in stage 1, 1 in every other stage, 0 when failed. Fill `RidgeFront` to the bottom. Crest stroke `SpendCrest`: `Crest` at 75%, 1.5pt.
- The lower line is a blend of the level floor and the target horizon, so it lifts towards the upper line everywhere at once and cannot cross it. At `g = 0` it is level; as it rises it takes on the horizon's shape; at `g = 1` the two coincide.
- **Merged:** one crest stroke at 90%. From there both rise together by the layout's lift through stage 2: 4pt on the strip, enough to read, never into the name.
- The gap at any x is `(1 − fill) × (Fl(x) − U(x))`. On the strip it is 6pt under the name and widens to about 22pt at the right, where the target horizon rises.
- The veil greys the crest strokes right of the marker, so the lit part of the spend crest glows and the rest reads cold.

#### Literal (alternative)

The owner may have meant the Spend Ridge's drawn line: cumulative spend by day from the period's start to today, which then, instead of ending, "goes horizontal" to the right edge.

- Lower line from x = 0 to today's x: `Fl(x) + min(1, cumulative(day) / target) × (U(x) − Fl(x))`, monotone cubic, no overshoot.
- From today's x to the right edge: today's level, drawn with the level formula so the "horizontal" run cannot cross the upper line.
- After the minimum, merged from the crossing day on, then rising with the stage-2 lift.

#### Recommendation: level

- **One horizontal meaning.** The literal line's x is days, while the marker's x is progress. Two meanings in one picture is exactly what the owner's first point removes.
- **Data.** The report carries no daily series. A literal line needs `periods[].daily` (date and cumulative qualifying spend) from the Worker. The phone's own transactions cannot reproduce exclusions, refunds, block rounding or category caps.
- **Honesty.** The level line's height comes from the same `fill` as the figure.

The literal reading is phase two at most, and then only in the sheet's hero. In code the scene takes a `RidgeStyle` with `.level` only, so `.literal(series:)` can be added later without touching anything else. The app ships no user-facing toggle. The lab page should carry a Level/Literal toggle on its live card, with a clearly labelled synthetic series, so the owner can compare the two.

### Rings

- Count: none in stage 1; from the sunrise point, `1 + floor((e − 0.6) / 0.1)`, at most 4; one when calm. They step in as the sun clears and climbs. The lit band carries the stage-1 read.
- On iOS, ring k is a soft annulus centred on the sun. It runs from `r + ρ(k − 0.35)` to `r + ρ(k + 0.05)`, where `ρ = σ × r × (0.8 + 0.4u)` and `u` is stage-2 progress. Each edge has a 1pt feather, so each step reads as posterised light, not a drawn line. Tune σ by eye against the web face at hero size.
- Colours: `Ring1` to `Ring4`, inner to outer. On the night sky draw rings with the screen blend mode, as web does, so they stay warm rather than olive.
- Halo opacity: `0.45 + 0.55 × e`. The core glow under the disc always draws when there is a sun.
- On the strip, the sun is right of 0.59 W whenever rings show, so ring 2's outer edge stays right of the name column (0.5 W). Rings 3 and 4 may pass behind the name: at 14% and 7% alpha they keep the day ink above 10:1.

### Strip, default text size

```
 W = 361pt (iPhone 16 with 16pt list insets), corner radius 16 (Theme.Radius.card)
┌──────────────────────────────────────────────────────────────┐  top padding 9
│ 🧳 Exposure Below      ┊░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░│  name, line ~23, max 0.50 W
│                        ┊░░░░░░░░░░░░░░░░░░░░░░░░░░░░___/‾‾‾‾‾│  target horizon rises right of 0.52 W
│‾‾\__/‾‾‾‾‾‾\__/‾‾‾‾‾‾‾(◒)‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\______/‾‾‾‾░░░░░░░░░│  target horizon, 13pt under the name
│                        ┊             gap: left to the minimum │
│‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾┊‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾│  spend horizon, lifting with spend
│ $184.50 to minimum     ┊                        8 days left  │  headline line ~22
│ $315.50 / $500.00 · $0.00 earned                             │  2, basis line ~15, bottom 9
└──────────────────────────────────────────────────────────────┘  about 104pt
   lit ───────────────── ┊ marker at x(e), e = 0.38 ── underexposed (░)
```

Height budget at `.large`: top padding 9, name 23, sky band 24 (13pt to the target horizon, 6pt of gap at the left, 5pt of ridge above the headline), headline 22, 2, basis 15, bottom 9. That is about 104pt, today's row height, so about 5 rows still fit on an iPhone 16.

| Element | Type | Ink |
| --- | --- | --- |
| Account emoji and name | Instrument Serif Italic 19pt, relative to `.title3`; at most 2 lines, then a tail truncation; at most 0.50 W | `InkDay` on day skies, `InkNight` on night skies |
| Amount | IBM Plex Mono SemiBold 17pt, relative to `.headline` | `FootInk`, or `FailedInk` for a failed card |
| Action label | IBM Plex Sans 15pt, relative to `.subheadline` | `FootInk` |
| Deadline, trailing | IBM Plex Sans 13pt, relative to `.footnote`; SemiBold when urgent | `FootInkSoft`; `UrgentInk` when urgent |
| Basis line | IBM Plex Mono 12pt, relative to `.caption1`; may wrap | `FootInkSoft` |

- The headline line keeps today's `ViewThatFits` behaviour (`RewardsView.swift:920-958`): if the action and the deadline do not fit on one line, the deadline drops below. The action never wraps mid-phrase.
- Padding is `@ScaledMetric(relativeTo: .body)`: 16 horizontal, 9 vertical.
- **Foot scrim.** A `RidgeFront` gradient at 55% runs under the foot text block, from its top edge down. The foot always sits on the spend ridge, so the scrim is a guard: no layout or text size can put light ink on a day sky.
- **Exceptions** go on a paper slip tucked under the frame, as on the web. The slip is 8pt narrower on each side, starts 10pt under the frame's bottom edge, uses `Theme.card` and has 12pt bottom corners. Lines are IBM Plex Sans Medium 13pt with today's triangle icon and inks (`RewardsView.swift:885-897`): at most 2, then "+N more". Each line adds about 20pt. The frame's height never changes for exceptions.
- The strip leaves out the chevron that today's title line has, and does not take the web face's issuer and type caps line or a Featured mark. See The Featured mark and open question 5.

### Paper row with print (register)

- `Theme.card`, radius 16, 14pt vertical and 16pt horizontal padding.
- Leading column: today's four-line content, with the strip's fonts but today's inks on paper (`Theme.textPrimary`, `Theme.rowSecondary`, the tone inks).
- Trailing: a 90 × 60pt print, radius 8 (`Theme.Radius.inset`), with a 0.5pt hairline at `Color.primary` 12%, top-aligned with the name. The gap to the text is 12pt. The print draws the whole scene, marker included; its falloff is about 7pt wide.
- The headline line is narrower here (about 227pt at W 361), so the deadline usually sits below the action.

### Hero (detail sheet)

```
┌── 6pt border in Theme.card, 0.5pt hairline ──────────────────┐
│ $500.00 minimum         ┊░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │  label, top leading; marker from 0.06 h
│                         ┊░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│                         ┊░░░░░░░░░░░░░░░░░░░░░░░░░░░___/‾‾‾‾‾│
│                         ┊░░░░░░░░░░░░░░░___/‾‾‾‾‾‾‾‾‾░░░░░░░ │  target horizon (brand back ridge)
│              ____/‾‾‾‾‾(◒)‾‾‾‾‾\__/‾‾‾‾‾╵‾‾░░░░░░░░░░░░░░░░░ │  ╵ sunrise tick at x(0.6)
│  ‾‾‾‾‾‾‾‾‾‾‾‾          ┊      gap: left to the minimum       │
│  ~~~~~~~~~~~~~~~~~~~~~~┊~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~│  spend horizon (front ridge)
│                         ┊                                    │
└──────────────────────────────────────────────────────────────┘
  1 Sep ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━│━━━━ 30 Sep   optional period track, below the art
```

- **Size.** The width is the sheet's content width, capped at 520pt on iPad. Inside a 6pt border the image is `(W − 12) × (W − 12) × 2/3`: 349 × 233pt on an iPhone 16. Outer radius 16, inner radius 10. The 3:2 ratio and the visible border make it read as a photographic print, not a payment card.
- **The scene** is the full version of the strip's: brand back ridge as the target horizon, a level front ridge at 0.80 h as the spend floor, the arc, the light and the marker. No pace line, no day ticks.
- **Target label.** One label, top leading, IBM Plex Mono 11pt: the basis target and kind ("$500.00 minimum", "$400.00 monthly minimum", "$1,600.00 next tier", "$1,000.00 bonus cap"). Only when there is a basis and the state is not calm or failed.
- **Sunrise tick.** In stage 1, a 4pt tick on the target horizon at `x(0.6)` shows where the lines will meet. `TargetCrest` at 60%.
- **Period track (optional).** Time may appear in the sheet only as a separate thin track **below** the art, never inside it: a 2pt rule from the window's start to its end, the elapsed part in `Theme.rowSecondary`, the rest at 30%, a 6pt as-of tick, and both dates at the ends in IBM Plex Mono 10pt. The window is the active month for a monthly minimum, otherwise the period containing the as-of day. The sheet computes it from the row's `periods` and `monthlyQualifications`, which it already has; the projection does not change. It is hidden from VoiceOver because the deadline clause already says it. It stays off until the owner answers open question 4.
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

Estimates: the strip is about 104pt at `.large` and 140 to 160pt at xxxLarge; the band row is about 280pt at AX1 with a two-line name. **Widths:** iPhone SE (3rd generation) gives W 343, iPhone 16 gives 361 and Pro Max gives 398. On iPad the row content is capped at 640pt and centred, because the board has no readable-width limit today and a 700pt-wide strip turns into a thin ribbon.

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

New files: `Support/RewardExposure.swift` (the mapping and the scene geometry), `Views/RewardExposureFace.swift` (the Canvas), `Views/RewardExposureRows.swift` (strip, paper row, hero), `Support/RewardTypography.swift` and `Fonts/`. The project lists files explicitly (`objectVersion = 56`), so add each one to `HowMuch.xcodeproj` and to the HowMuch target.

### No projection additions

Version 1 added `window` and `elapsed` to `RewardRowProjection` only to place the sun in time. Version 2 drops both. The mapping reads `action`, `fill`, `basis?.target`, `deadline?.end` and `rewardType`, which the projection already has. The optional sheet period track computes its window in the sheet.

### The mapping: `RewardExposure`

The mapping lives in one place: `RewardExposure.init?(_:)`, a pure function of a `RewardRowProjection`. It is the mapping table in code. The web port mirrors it as `exposure(projection)`. Its isolated test is written first; see Verification.

```swift
// Sketch, unverified (no Xcode here).
struct RewardExposure: Equatable {
  enum Stage: Equatable { case gate, headroom, full, calm, failed }
  static let sunrise = 0.6

  var stage: Stage
  var e: Double            // 0...1; the sunrise point when calm; unused when failed
  var night: Bool
  /// Changes when the target does: another action kind, basis target or deadline end.
  var target: String

  var hasMarker: Bool { stage == .gate || stage == .headroom || stage == .full }

  /// The share of the way to the gate, which sets the ridge gap.
  func gateFill(at e: Double) -> Double {
    switch stage {
    case .gate: return min(1, max(0, e / Self.sunrise))
    case .failed: return 0
    default: return 1
    }
  }

  /// Nil for range rows, which draw no picture.
  init?(_ p: RewardRowProjection) {
    let fill = min(1, max(0, p.fill ?? 0))
    switch p.action {
    case .range:
      return nil
    case .qualificationFailed:
      stage = .failed; e = 0
    case .monthlyMinimum, .minimum:
      stage = .gate; e = Self.sunrise * fill
    case .nextTier, .capHeadroom:
      stage = .headroom; e = Self.sunrise + (1 - Self.sunrise) * fill
    case .capReached:
      stage = .full; e = 1                  // the projection pins fill to 1
    case .minimumMet, .topTier, .noTarget:
      stage = .calm; e = Self.sunrise
    }
    night = p.rewardType == .miles
    target = "\(Self.kind(p.action))|\(p.basis?.target ?? 0)|\(p.deadline?.end ?? "")"
  }

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
```

The rings, the arc, the veil edge and the ridge lines are functions of `(layout, size, e)` in `ExposureScene`, so an animated `e` moves all of them together.

### `RewardExposureFace`: one `Canvas`

The face is a single `Canvas`. It is not a stack of `Shape` views.

- **One pass, one layer.** A list row needs about ten layers: sky, horizon, bloom, up to four rings, the disc, two ridges and their crests, the veil and the marker. As `Shape` views that is a dozen views per row with their own identity and diffing, times every visible row. `Canvas` draws them in one immediate-mode pass and keeps the result until its inputs change. Scrolling never redraws it.
- **Geometry stays in one place.** A pure `ExposureScene(size:layout:exposure:e:scale:)` computes everything and the Canvas draws it. The web port mirrors the same functions.
- **One animatable value.** The face conforms to `Animatable` with `e` alone. SwiftUI interpolates it and the scene recomputes the sun, the light, the ridges and the marker from it each frame, so the sun follows the arc, not a straight line.
- **Text stays out.** Every word is a real `Text` outside the Canvas, so Dynamic Type, Bold Text, VoiceOver and OCR keep working. The Canvas is `accessibilityHidden(true)` and `accessibilityIgnoresInvertColors(true)`, because Smart Invert must not turn a print into a negative.

```swift
// Sketch, unverified.
struct RewardExposureFace: View, Animatable {
  var exposure: RewardExposure
  var layout: ExposureLayout     // .strip(nameBottom:footTop:), .print, .band, .hero(showsLabels:)
  var e: Double                  // animated; exposure.e at rest
  @Environment(\.displayScale) private var scale

  var animatableData: Double {
    get { e }
    set { e = newValue }
  }

  var body: some View {
    Canvas { context, size in
      let scene = ExposureScene(size: size, layout: layout, exposure: exposure, e: e, scale: scale)
      if exposure.stage == .failed { context.addFilter(.saturation(0.15)) }
      scene.drawSky(in: &context)       // sky, horizon warmth, bloom
      scene.drawSun(in: &context)       // halo, rings, disc; nothing when failed
      scene.drawRidges(in: &context)    // target horizon, spend horizon, crests
      scene.drawScrim(in: &context)     // strip only
      scene.drawVeil(in: &context)      // two blend-mode gradient fills
      scene.drawMarker(in: &context)    // two tones, broken across the visible disc
    }
    .accessibilityHidden(true)
    .accessibilityIgnoresInvertColors(true)
  }
}

extension ExposureScene {
  func drawVeil(in context: inout GraphicsContext) {
    guard let edge = veilEdge else { return }      // nil when calm; failed veils everything
    let rect = Path(CGRect(origin: .zero, size: size))
    let from = CGPoint(x: edge, y: 0), to = CGPoint(x: edge + 0.08 * size.width, y: 0)
    var veil = context
    veil.blendMode = .saturation
    veil.fill(rect, with: .linearGradient(
      Gradient(colors: [.clear, Theme.Face.veilGrey.opacity(0.5 * strength)]), startPoint: from, endPoint: to))
    veil.blendMode = .multiply
    veil.fill(rect, with: .linearGradient(
      Gradient(colors: [.white, veilColour.mix(with: .white, by: 1 - strength)]), startPoint: from, endPoint: to))
  }
}
```

`strength` is `1 − bloom`. Past the gradient's end the end colour holds, so everything right of the falloff gets the full veil.

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
      RewardCardTitle(projection.title, icon: icon, onNight: projection.rewardType == .miles)
        .frame(maxWidth: width * 0.50, alignment: .leading)   // the sun clears the horizon right of here
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
| `Crest` | #FFD98C; the target crest at 40%, the spend crest at 75%, merged at 90% | 70%, 100%, 100% | `--ridge-crest` |
| `SunDiscTop`, `SunDiscBottom` | #FFFDF6, #F8E6BA | same | `--sun-disc` |
| `SunRim` | #DFA050, drawn at 60% | same | `--sun-rim` |
| `SunCore` | #FFD382 | same | `--sun-core` |
| `SunCoreUnder` | #E2A95C (stage 1) | same | `--glow-edge` |
| `Ring1` to `Ring4` | #FFD27A at 78%, #FFA452 at 28%, #F08446 at 14%, #D8604A at 7% | same | `--face-ring-1` to `--face-ring-4` |
| `Horizon` | #FFAD5C at 17% | same | `--face-horizon` |
| `VeilGrey` | #808080, saturation blend, alpha 0.5 | same | new `--face-veil-grey` |
| `VeilDay` | #D4CBD4, multiply | same | new `--face-veil-day` |
| `VeilNight` | #8A8496, multiply | same | new `--face-veil-night` |
| `Bloom` | #FFE3AC at 30% | same | new `--face-bloom` |
| `MarkerDay` | #94591A at 55% | 75% | new `--face-marker-day` (the value of `--glow-ink`) |
| `MarkerNight` | #FFD98C at 35% | 55% | new `--face-marker-night` |
| `MarkerRidge` | #F7F5EF at 22% | 35% | new `--face-marker-ridge` |

Version 1's `Afterglow`, `Dim`, `PaceDay` and `PaceNight` are not needed.

**Contrast on the faces** (WCAG relative luminance, computed from the values above; confirm with the OCR snapshot and Accessibility Inspector):

| Text or mark | Background | Ratio |
| --- | --- | --- |
| `FootInk` | `RidgeFront` | 10.0:1 |
| `FootInkSoft` | `RidgeFront` | 8.1:1 |
| `UrgentInk` | `RidgeFront` | 8.1:1 |
| `FootInk` | `RidgeFront` under the night veil | 15.4:1 |
| `FailedInk` | `RidgeFront`, veiled, at saturation 0.15 | 9.4:1 |
| `InkDay` | `SkyDay3`, the darkest day stop | 10.3:1 |
| `InkDay` | `SkyDay3` under the day veil | 6.6:1 |
| `InkDay` | `SkyDay3` under the bloom | 11.3:1 |
| `InkNight` | `SkyNight1` | 15.2:1 |
| `InkDay`, `InkNight`, `FootInk` | a marker pixel on their background | 5.5:1, 5.7:1, 5.4:1 |
| `MarkerDay` (non-text) | day sky stops; veiled `SkyDay3` | 1.9 to 2.1:1; 1.5:1 |
| `MarkerNight` (non-text) | night sky, veiled or not | 2.7:1 |
| `MarkerRidge` (non-text) | `RidgeFront`, `RidgeBack` | 1.85:1, 1.6:1 |

Text never sits on the back ridge or across a crest stroke.

**Chrome stays in code.** In `Support/Theme.swift`, `RewardTonePalette` keeps only `ink`. Track and fill go with `RewardFilledRow`. `.complete` gets the web's `--tone-complete` dusk: light #5F5457, dark #BCAEB4, Increase Contrast light #4A4044 and dark #D6CBD0. That is 7.3:1 on white and 7.6:1 on the dark card. `.failed` keeps its red. Exceptions for capped categories therefore read in dusk, not alarm red, which matches "done, not failed". Print borders and slips use `Theme.card`.

### Performance with 20 or more cards

- `List(.plain)` is already lazy. One Canvas per realised row, with no `.blur`, `.shadow`, material, `.drawingGroup()` or `TimelineView` per row. Rings are radial gradients, the veil is two linear-gradient fills with blend modes, the bloom is one fill, and monochrome is one colour-matrix filter.
- The face is `Equatable` on (exposure, layout, e) and applied with `.equatable()`. `RewardsBoard` is rebuilt on every `body` (`Views/RewardsView.swift:158-160`), and unchanged cards must not redraw.
- Build ridge paths once per layout as unit paths, scale them with a transform, and keep the crest table `static`. The spend line is a per-frame blend of two sampled lines (65 points), which is cheap.
- Only animating rows redraw per frame: at most the visible rows (about five) for 0.6s after data arrives.
- The context-menu preview renders the same row, and the swipe action is unchanged.
- **Check:** the 28-card fixture below, flung top to bottom and back, with Instruments' Animation Hitches template. The simulator gives an indication only. Real evidence needs a device run, which needs a signed build the owner authorises.

## Motion

Timings are `Theme.Motion` (`Support/Theme.swift:180-189`). The web uses the same values through its tokens (`--dur-fill` 600ms, `--dur-standard` 320ms, `--dur-arrive` 400ms, `--stagger` 28ms). Only `e` animates. Everything in the art is recomputed from it.

| Moment | Animation | Reduce Motion |
| --- | --- | --- |
| A card is first shown this session | The List's existing arrival (`arrive`, 0.4s). `e` rises from 0 to its value with `chart` (0.6s): the sun travels the arc from the left horizon, the lit edge sweeps right, the spend line lifts, and rings step in once the sun clears. Stagger 28ms × min(index, 12). | Drawn in place. No rise. |
| Scrolled back into view | Nothing: it was already shown | Same |
| Same target, new figures (refresh, a new transaction, the as-of date stepped) | `e` glides with `chart`; a refund may glide it back. Figures crossfade in place over 0.18s with `.contentTransition(.opacity)`. | `e` jumps. Figures crossfade, since opacity is allowed. |
| A target change where `e` rises (the minimum is met) | `e` glides with `chart`: the spend line meets the target horizon as the sun clears it, then the merged ridge and the sun go on. Entering calm, the marker and the veil fade out over `standard`. | Jump |
| A target change where `e` would fall (a tier reached, a new month or period) | The face crossfades over 0.32s (`standard`) to the new state. The marker never glides backwards. | Jump |
| A refresh reaches the cap | `e` glides to 1 with `chart`; the bloom fades in over the last stretch (0.96 to 1). No separate sunset. | Jump to full |
| Tap | Scale 0.99 with `press` (0.18s), no opacity change. Today's `PressableButtonStyle` (0.97 and 0.85) is too strong for a picture. | Opacity 0.9, no scale |
| Opening the sheet | The system sheet. A zoom from row to hero is optional (see the open questions). | System |
| Idle | Nothing. No `TimelineView`, shimmer, pulse or drifting rings. | Same |

**Interpolation.** `e` interpolates through `animatableData`, and the scene places the sun on the arc for each frame's `e`, so the sun follows the arc and the marker and the lit edge move in step with it. Use `Theme.Motion.chart`, which is `.smooth` with no bounce. Never use a bouncy spring: overshoot would briefly show progress the ledger has not reached.

**No counting.** Text never counts. Use `.contentTransition(.opacity)` only. Never use `.numericText` or the register's `.rollingNumber` (`Views/Components.swift:186-195`) on the card.

**Rising once.** A lazy `List` creates rows again as they scroll, so `onAppear` alone would replay the rise. Keep the last `e` shown per card, with its target, in a session-only memory keyed by plan and card. A row that appears starts from the remembered `e` when the target is the same (or 0 the first time), and animates only if the value differs. If the target changed while the row was off screen, it appears in place.

```swift
// Sketch, unverified.
@MainActor @Observable final class ExposureMemory {
  var shown: [String: (target: String, e: Double)] = [:]   // plan | card
}

struct RewardExposureAnimator: View {
  let exposure: RewardExposure
  let layout: ExposureLayout
  let key: String
  var index = 0
  @Environment(ExposureMemory.self) private var memory
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var shown: Double?
  @State private var faceID = ""     // changes only when a target change makes e fall

  var body: some View {
    RewardExposureFace(exposure: exposure, layout: layout, e: shown ?? exposure.e)
      .equatable()
      .id(faceID)
      .transition(.opacity)
      .onAppear {
        let last = memory.shown[key]
        let start = last == nil ? 0 : (last!.target == exposure.target ? last!.e : exposure.e)
        faceID = exposure.target
        shown = reduceMotion ? exposure.e : start
        memory.shown[key] = (exposure.target, exposure.e)
        guard !reduceMotion, start != exposure.e else { return }
        withAnimation(Theme.Motion.chart.delay(Double(min(index, 12)) * 0.028)) { shown = exposure.e }
      }
      .onChange(of: exposure) { old, new in
        memory.shown[key] = (new.target, new.e)
        if new.target != old.target, new.e < old.e {
          // Never glide backwards: swap the face and crossfade.
          withAnimation(reduceMotion ? nil : Theme.Motion.standard) { faceID = new.target; shown = new.e }
        } else {
          withAnimation(reduceMotion ? nil : Theme.Motion.chart) { shown = new.e }
        }
      }
  }
}
```

Confirm on device that the `.id` swap crossfades inside a List row's background, and fall back to an explicit two-face `ZStack` with opacity if it does not.

Also fix the list-wide `.animation(Theme.Motion.arrive, value: model.rewardsPhase)` (`Views/RewardsView.swift:186`), which does not check Reduce Motion today.

## Accessibility

- **One element per card, as today.** The label is the card name, the value is `RewardRowText.accessibilityValue`, the hint is "Shows details.", and the custom actions are Edit Rewards and Hide (`Views/RewardsView.swift:396-404`). The register row keeps "Rewards, <name>" and its hint (`:1720-1722`). The slip is part of the same element. The face, emoji and every in-frame label are hidden.
- **Nothing new is spoken.** The value string stays pinned by `testAccessibilityValueStatesTargetProgressAndDeadline` (`apps/ios/HowMuchTests/RewardsReportTests.swift:1413`). `e` is a picture coordinate and is never spoken: the spoken percentage stays the basis's. The art stays decorative. The issuer, newly visible in the sheet, is offered through `accessibilityCustomContent("Issuer", issuer)` in the More Content rotor, and "Featured" the same way when it applies.
- **Dynamic Type.** Every font is relative to a text style, and padding uses `@ScaledMetric`. The strip grows with its text. At accessibility sizes, every row becomes the paper row with a band, so text never sits on fixed-ratio art.
- **Contrast on the faces.** See the contrast table. Text sits only on the sky above the target horizon or on the spend ridge, and never across a crest stroke or over rings 1 and 2. The day veil is capped so dark ink keeps 6.6:1 on it.
- **Increase Contrast.** Today's 1pt outline at `Color.primary` 30% stays, on the strip and on the print. The High Contrast colour sets darken the ridges and lighten the foot inks. The crest strokes and the marker draw at their Increase Contrast opacities.
- **Differentiate Without Colour.** Each state differs in shape and luminance, not just colour: the marker's position, the lit edge (a luminance step), the ridge gap, the sun's height, the ring count, a sun or none, plus the headline words.
- **Smart Invert.** Faces ignore invert, like photographs.
- **Reduce Transparency.** Nothing to change: there is no material, and figures stay on opaque surfaces.

## Web parity

The web face already draws a sky, the brand ridges and a sun. Parity means the web takes the iOS row's rules and the same `e`, marker and ridge model, so both platforms show the same state for the same report.

### 1. Port the projection, tests first

Per `AGENTS.md`, isolation is justified here. The web's R1 helpers (`cardTone`, `capIsPrimary`, `cardFill` at `apps/web/src/pages/Rewards.tsx:481-505`) have concrete bugs that the browser recipe only catches for states its fixture reaches:

- an intermediate cap is marked complete;
- a failed qualification shows before its month closes;
- the server's `minimum_spend_progress` drives the fill.

The rounding and Singapore-day rules have edge cases no fixture reaches.

- **Write the tests first.** Create `apps/web/src/lib/reward-row-projection.test.ts` before any implementation. Port every case of `RewardRowProjectionTests` with the Swift test name in each test title and the same hand-derived expected strings, plus the exposure walk below. Configure the same SGD format the Swift tests use (`configureMoney` in `apps/web/src/lib/money.ts`). Run it red against a stub that exports only the types.
- **Then the module.** `apps/web/src/lib/reward-row-projection.ts` exports `projectRow(row, asOf, isRange)`, `rowText(projection)`, `boardSummary(report, projections)`, `exposure(projection)`, the crest table and the scene helpers (`exposureScene(layout, size, exposure, e)`: sun centre, ring count, veil edge and strength, bloom, marker x and its split at the horizon, and both ridge path strings). Civil dates use string parts and `Date.UTC`, never a local `Date`.
- **Run it** with `bun test apps/web/src/lib/reward-row-projection.test.ts`, and again under `TZ=America/Los_Angeles` and `TZ=Pacific/Kiritimati` for the deadline days.

### 2. `Rewards.tsx`

- Delete `cardTone`, `capIsPrimary` and `cardFill`. `RewardCard` (`:543-569`) builds one projection and one exposure per row and sets:
  - `data-tone` (needs, earning, complete, failed or neutral, from the projection);
  - `data-stage` (gate, headroom, full, calm or failed) and `data-mono` for failed;
  - inline `--rw-e` at rest, replacing `--rw-p`. Drop version 1's `--rw-t` and `--rw-base`.
- **The face** (`RewardTile`, `:694-701`):
  - The CSS-positioned sun and halo spans stay, so they stay circular, now placed by `--sun-x` and `--sun-y`.
  - The ridge SVG (`preserveAspectRatio="none"`) gains the two computed ridge paths (target horizon and spend horizon) with their crests, two veil rects and the marker's two `<line>` segments. Strokes use `vector-effect: non-scaling-stroke`, and the marker adds `shape-rendering: crispEdges`.
  - The brand paths at `:698-700` become the target horizon's source shape and the crest table.
- **Animation.** `e` is tweened by a small new `apps/web/src/lib/exposure-tween.ts`: `requestAnimationFrame` over the computed `--dur-fill` with the `--ease-out` curve, starting after `--stagger` × min(index, 12) on first show. Each frame it writes the scene's CSS variables and path `d` attributes through refs, so React does not re-render per frame. Under reduced motion `tokens.css:102-108` zeroes `--dur-fill`, so the tween jumps. This keeps the sun on the arc in every browser; a CSS transition would cut straight across it, and Safari cannot transition `d`. A falling target change swaps the face with the existing opacity transition instead of tweening back.
- **The slip.** The slip (`RewardTile`, `:682-792`) replaces the R2 placeholder at `:718` with the headline: the amount in IBM Plex Mono, the label, and `<span className="rw-deadline" data-urgent>`. Then come the basis line and the exceptions (at most 2, then "+N more").
- **Featured.** The `✦` badge (`:704`) becomes the word: "Featured" joins the caps line as text on the desktop face. The badge's `title` and the screen-reader span go. The phone strip has no caps line and no Featured mark.
- The two `ExposureMeter`s, the Spend, Eligible and Value stats, and "Consider another card" move into the disclosure, renamed **Targets, periods and tiers**. On desktop the flag list stays in the slip. On phones it moves into the disclosure, matching iOS, which keeps categories in the sheet.
- The hero's R2 placeholder (`:210`) becomes the ported summary line, for example "2 below minimum · 1 capped".

### 3. `rewards-board.css` and `tokens.css`

- **Tokens.** Replace `@property --rw-p` (`tokens.css:16`) with `@property --rw-e`. Add the constant face tokens `--face-foot-soft`, `--face-urgent-ink`, `--face-failed-ink`, `--face-veil-grey`, `--face-veil-day`, `--face-veil-night`, `--face-bloom`, `--face-marker-day`, `--face-marker-night` and `--face-marker-ridge` with the values in the colour table. Faces stay identical across Dusk Ridge, Ridge Charcoal and Overexposed: the looks differ only in chrome colour.
- **Sun and halo** (`:529-565`): place them from the scene, not the fixed 76% column.

  ```css
  /* Sketch. --sun-x and --sun-y are written by the tween from exposureScene. */
  .rw-face-sun { left: var(--sun-x); top: var(--sun-y); }
  .rw-face-halo { background: radial-gradient(circle at var(--sun-x) var(--sun-y), /* shipped bands */); }
  ```

- **Rings.** Gate them with `data-rings` (0 to 4), for example by setting `--face-ring-3` and `--face-ring-4` to transparent under `[data-rings="2"]`, and keep the shipped band geometry.
- **Veil.** Two `<rect>`s across the face with a horizontal gradient from `--veil-x` over 8% of the width: one with `mix-blend-mode: saturation` (`--face-veil-grey`), one with `mix-blend-mode: multiply` (`--face-veil-day` or `--face-veil-night` by `data-type`). The face is already `isolation: isolate`. `[data-stage="calm"]` hides them; `[data-stage="failed"]` sets them to full strength everywhere.
- **States.**
  - Delete the `[data-tone="complete"]` sunset rules (`:649-664`): a cap is now `[data-stage="full"]`, with the bloom and no dim.
  - `[data-mono]` replaces `saturate(0.35)` (`:666-668`) with 0.15, and hides the sun and halo.
  - `[data-stage="gate"]` takes over the `needs` core rule (`:644-646`), so the amber follows the stage.
  - Delete the `rw-expose` keyframe (`:476-480`) and the `--rw-p` transition and `rw-expose` animation on `.rw-card` (`:464-465`): the tween replaces them. `rw-arrive` stays.
- **Phones** (`@media (max-width: 720px)`, `:1087`): the card becomes the strip. The name sits on the sky, and the headline and basis line sit on the spend ridge. `N` and `F` are measured with a `ResizeObserver`. The slip carries exceptions only. This replaces the 21:9 face.

### 4. Not in this slice

The web board keeps its own Arrange orders (Manual, Name, Reward value, Spend) and has no detail sheet, so there is no web hero or period track. The `/rewards/:cardId` edit page could take the hero later.

## Verification

iOS checks run on the Mac runner through `scripts/ios-xcodebuild.sh` and the Simulator (see `apps/ios/AGENTS.md`). Linux cannot run them. Store every artifact under `.amp/in/artifacts/rewards-exposure/{ios,web}/`, which overrides the older paths in the recipes.

### Failure modes first

| # | Failure mode | Caught by |
| --- | --- | --- |
| 1 | Picture and figure disagree: `e` from anything but the projection's `fill`, or `fill` from server progress fields | iOS: the existing projection tests, where fill and basis share one source. Web: the port's tests, written first. E2E: measure each fixture card's marker x against its expected `e`. |
| 2 | Web precedence wrong: intermediate cap set as complete, failure shown before its month closes, rewards implied unlocked | The port's tests, written first; E2E cards E, J, K and L |
| 3 | A stage assigned wrongly, so more spend moves the marker back within one target. For example, a next tier in stage 1 sinks the sun on the day a tiered card meets its minimum. | **The isolated exposure walk, written first** (below). E2E card O shows one point of it. |
| 4 | Time leaks back into the art: equal `e` drawn at different places in rows with different dates | E2E: cards A and B share $315.50 / $500.00 with different periods and deadlines. Their marker x and sun centre must match within 1pt. |
| 5 | Text illegible on the art: the marker or the day veil under a long name, rings behind the name, light ink on a day sky | The existing OCR snapshot test, retargeted; E2E card N (a long name over the marker at `e` 0.38) in light, dark, AX3 and Increase Contrast |
| 6 | The light does not read: blend modes dropped by a renderer, so the right side is not dim | E2E: sample pixels on card A's sky 10% left and 15% right of the marker. The right sample must be darker and less saturated, on day and night skies. |
| 7 | VoiceOver drifts: the art becomes focusable or the value string changes | The existing pinned value test (`:1413`); an E2E accessibility dump showing one element per card |
| 8 | The rise replays on every scroll, or plays under Reduce Motion | E2E recordings |
| 9 | A falling target change glides the marker backwards instead of crossfading | E2E: card O crossing its tier (step 7) |
| 10 | Overshoot shows progress the ledger has not reached | E2E recording at 60fps, reviewed frame by frame where each glide ends |
| 11 | Fonts not bundled, falling back to SF silently | E2E screenshots and the DEBUG launch assertion |
| 12 | Scroll hitches with 20 or more cards | E2E with the 28-card fixture and Instruments; a device run by the owner |
| 13 | Dynamic Type clips text in a fixed frame | E2E at AX3; the existing snapshot at `.accessibility1` |
| 14 | The partial-block cap reads as false | E2E card G, checked against the rule above |

### Isolated tests: only these, written before the implementation

**The exposure walk** (iOS in `RewardRowProjectionTests`; web in the port's suite). It covers failure mode 3, which no fixture can sweep.

- **The card.** The shape of `fixtures/rewards-account-config.json`: a minimum of 100, tiers at 0 and 1,000, a cap of 2,400 below the tier and 3,000 from it, and earning blocks of 5.
- **The walk.** Spend from −50 (a refund-heavy period) to 3,200 in $5 steps.
- **The inputs.** For each step, build the row the server would send, from rules written in the test independently of the projection: `minimum_spend_met` once spend reaches 100, `has_next_spending_tier` below 1,000, counted spend in whole blocks, and `maximum_spend_exceeded` once the headroom is under one block.
- **The assertions.**
  - `e` is finite and within 0 to 1.
  - `e` is below 0.6 exactly while the action is a minimum.
  - `e` is 1 exactly when the action is `capReached`.
  - Between consecutive steps `e` never decreases unless the exposure's `target` changed.
- **Expected values** come from the stage rules in this document, not from the implementation.

**Web:** the port's suite, as described in Web parity, plus the walk and the two `TZ` runs.

Do not write tests for the mapping table row by row (E2E reaches every row through the fixture), geometry constants, colour values, font names or view structure. Version 1's four `elapsed` tests are dropped with `elapsed`.

**Existing tests to retarget** (keep their intent and expectations; these are not new tests):

- `testStatusRowsRenderLightDarkAndLargeText` (`apps/ios/HowMuchTests/RewardsReportTests.swift:1422-1506`): render `RewardExposureRow` at `.large`, and the band row at `.accessibility1`. Its OCR expectations stay the same. OCR finding the text in five appearances is the legibility proof.
- The detail sheet snapshots (`:651`, `:680`, `:837`) now render the hero and slip, with unchanged expectations.
- `apps/web/src/lib/rewards-tile.test.ts`: the historical tile still reads the cutoff period's minimum. The meters and stats move into the disclosure but stay in the markup, so its positive and negative assertions stand. Do not weaken them.

### States fixture

Add `fixtures/rewards-exposure-states.json`, a Rewards Tracker export. An import replaces the stored card set, so it includes Travel Card. Every card is bound to `acct-credit`. The demo ledger's Travel Card spend is $26.40 in March (11 Mar, red flag), $488.90 in April (12 Apr, red) and $315.50 in May (4 May $228.90 blue, 13 May $86.60 red). As of **24 May 2026**, a calendar card has 8 days left.

Expected values are worked out by hand from those numbers. Before taking screenshots, confirm each one against `GET /api/reports/rewards?plan_id=local-plan&to=2026-05-24`. If the server disagrees, the server is right: change the card's thresholds and record why. Never quietly change an expectation.

| Card | Configuration | Expected headline · deadline | Expected basis | Picture |
| --- | --- | --- | --- | --- |
| A Exposure Below | Cashback, calendar, minimum 500, rate 1 | $184.50 to minimum · 8 days left | $315.50 / $500.00 | Gate, `e` 0.379; spend line 63% of the way up; amber core; no rings |
| B Exposure Urgent | Cashback, billing day 26, minimum 500 | $184.50 to minimum · 2 days left, urgent | $315.50 / $500.00 | Identical art to A. Confirm the period is 26 Apr to 25 May. |
| C Travel Card | As today: miles, minimum 200, Dining 4, Online 3 | Minimum met · Resets in 8 days | $315.50 / $200.00 · 1,033 miles earned | Calm on a night sky: no marker, merged, evenly lit |
| D Exposure Headroom | Cashback, maximum 1,000 | $684.50 left before bonus cap · 8 days left | $315.50 / $1,000.00 | Headroom, `e` 0.726, 2 rings |
| E Exposure Tier | Miles, tiers at 0 and 400 | $84.50 to next tier · 8 days left | $315.50 / $400.00 | Headroom, `e` 0.916, 4 rings |
| F Exposure Capped | Cashback, maximum 300, rate 1 | Bonus cap reached · Resets in 8 days | $300.00 / $300.00 · … · $15.50 beyond cap | Full: `e` 1, bloom, no dim |
| G Exposure Block | Cashback, maximum 314, earning block 5 | Bonus cap reached · Resets in 8 days | $310.00 / $314.00 · … · $1.50 beyond cap | Full, with a raw figure under 100%. Confirm `counted_spend` 310 and `maximum_spend_exceeded`. |
| H Exposure Top | Cashback, minimum 300, one tier at 300 | Highest tier active · Resets in 8 days | $315.50 spent · … | Calm |
| I Exposure Open | Cashback, no minimum or cap | No cap · Resets in 8 days | $315.50 spent · … | Calm |
| J Exposure Failed | Miles, 3-month period from 1 Mar, monthly minimum 100 | March minimum missed · Resets in 8 days | $830.80 spent · … | Monochrome, no sun, no marker, ridges apart, veiled throughout |
| K Exposure Monthly | Cashback, 3-month period from 1 Apr, monthly minimum 400 | $84.50 to monthly minimum · 8 days left | $315.50 / $400.00 | Gate, `e` 0.473, spend line 79% of the way up |
| L Exposure Locked | Cashback, 3-month period from 1 Apr, monthly minimum 300 | No cap · Resets in 38 days, slip "Rewards unlock after 30 Jun" | $315.50 spent · … | Calm. Confirm the month list and status. |
| M Exposure Category | Miles, minimum 200, Online capped at 200 | Minimum met · Resets in 8 days, slip "Online over cap" | $315.50 / $200.00 · … | Calm |
| N A long name, such as "Exposure Long Name Preferred Platinum Rewards" | As A | As A, name on two lines | As A | As A, ridges lower; the marker crosses the name |
| O Exposure Step | Cashback, minimum 200, tiers at 0 and 400 | $84.50 to next tier · 8 days left | $315.50 / $400.00 | Headroom, `e` 0.916, merged: a met minimum keeps the sun up |

The performance variant (`fixtures/rewards-exposure-states-28.json`) holds each card twice.

### iOS recipe: `.cursor/skills/verify-howmuch/features/ios-rewards.md`

**First, fix stale lines.** The recipe predates the filled-rows board. The board has no date-range chip and no Group chip, because groups live in Range Report. The empty state reads "No Reward Cards", not "No reward cards in this range.". "Tap the rewards bar" becomes "tap the rewards row".

**Then add these sub-features:** `ios-rewards-exposure-states`, `ios-rewards-exposure-sheet`, `ios-rewards-exposure-motion`, `ios-rewards-exposure-register` and `ios-rewards-exposure-accessibility`. Steps:

1. **Set-up** (not under test). Launch with `control-howmuch launch` and pass `doctor`. Import the states fixture through web **Settings → Rewards import**. Sign the Simulator in, and enable Simulator accessibility as `apps/ios/AGENTS.md` describes.
2. **States.** Rewards → Featured menu → **All Cards**. Today menu → **Choose Date…** → 24 May 2026 → **Done**. For each card, screenshot the row and dump its accessibility element. Compare the text and value with the fixture table and the state tables. Measure each marker's x against `m + e × (W − 2m)`, and compare A and B (failure mode 4). Sample A's sky either side of the marker (failure mode 6).
3. **Sheet.** Open A: the marker at 0.38, the ridges apart, the label "$500.00 minimum" and the sunrise tick. Then open K, D (headroom from 0.6, merged), F (full, bloom) and J (monochrome). Screenshot each hero.
4. **Appearances.** Screenshot A, C, F, I, J and N again:
   - dark: `xcrun simctl ui "$UDID" appearance dark`;
   - AX3: `xcrun simctl ui "$UDID" content_size accessibility-extra-extra-extra-large`, which must give paper rows with bands;
   - Increase Contrast: Settings → Accessibility → Display & Text Size, or `simctl ui` where the installed Xcode supports it.
5. **Motion** (record with `xcrun simctl io "$UDID" recordVideo`). Relaunch and open Rewards: each sun travels the arc from the left once, staggered, with the lit edge sweeping right. Scroll to the end and back: no replay.
6. **Register glide and persisted write** (record). This step uses a fresh stack with `fixtures/rewards-tracker-export.json`, so the register shows one row. Open Accounts → Travel Card. Today's month has no demo spend, so the row reads "$200.00 to minimum · N days left": mostly dark, a sliver of sun on the left. Add a transaction: $100.00, payee "Exposure check", today. Back in the register, the marker glides to 0.3 of the print's width, the lit edge follows, the spend line lifts halfway to the target horizon, and the row reads "$100.00 to minimum". Persisted proof:
   - `control-howmuch http GET "/v1/plans/local-plan/transactions"` lists the transaction;
   - `control-howmuch http GET "/api/reports/rewards?plan_id=local-plan&account_ids=acct-credit"` shows `total_spend` 100 against `minimum_spend` 200.
7. **Cap and target changes** (record, states fixture, as of today).
   - F reads "$300.00 left before bonus cap", and O reads "$200.00 to minimum".
   - Add $320.00 to Travel Card. When the board refreshes:
     - F and G glide to full and bloom once;
     - O's spend line rises to meet the target horizon, the sun clears, and the card reads "$80.00 to next tier";
     - other cards glide; none reach full except F and G.
   - Add $90.00 more. O reaches its tier and becomes calm ("Highest tier active") with a crossfade, not a backward glide.
   - Reopen the board: no replay.
8. **Reduce Motion** (record). Turn on Settings → Accessibility → Motion → Reduce Motion and repeat step 6 with $50.00. The marker jumps with no glide, and step 7's changes do not animate.
9. **Accessibility dump.** One element per card, labelled with the card name, valued with the table string, and nothing for the art.
10. **Performance.** With the 28-card fixture, fling the board with Instruments' Animation Hitches template running. Record the simulator's limits, and leave the device check to the owner.

**Proof.** `RECORD.md` holds:

- the revision: `git rev-parse HEAD`, plus a diff hash if the tree is dirty;
- the fixture checksum, the Simulator model and the iOS version;
- the exact commands and steps, expected against observed.

Also save:

- screenshots named `{card}-{appearance}.png` and `hero-{card}.png`;
- recordings `load.mp4`, `register-glide.mp4`, `cap-and-targets.mp4` and `reduce-motion.mp4`;
- accessibility dumps `ax-board.txt` and `ax-register.txt`;
- the marker measurements and pixel samples, with the GET JSON.

A screenshot alone does not prove step 6: the GET output does.

### Web recipe: `.cursor/skills/verify-howmuch/features/rewards.md`

- **Open filled.** The face's headline now reads "Minimum met · Resets in 8 days" with the basis line. "Full-period minimum met" moves inside **Targets, periods and tiers**.
- **New `rewards-exposure-states`.** Import the states fixture through Settings → Rewards import and open `/rewards?to=2026-05-24`. For each card:
  - check the slip text and the `data-stage`, `data-rings` and `data-mono` attributes against the fixture table;
  - check the marker line's x against `e`.
  Do it at 1440 × 900 (3:2 face) and 390 × 844 (strip). Screenshot Dusk Ridge light and dark, plus one other look. The faces must be pixel-identical across looks; only the chrome differs.
- **Featured.** On the desktop face a featured card's caps line ends in the word "Featured". The phone strip shows no mark.
- **Motion.** Step the as-of date with **Next day** and record a Playwright video: the marker and the lit edge glide, the sun stays on the arc, and the figures settle without counting. Under `page.emulateMedia({ reducedMotion: "reduce" })`, the first frame already shows the final `--rw-e`.
- **Proof** goes in `.amp/in/artifacts/rewards-exposure/web/`, with the same `RECORD.md` fields.

## Open questions for the owner

The owner's 7 Oct review answered version 1's questions on the sun's horizontal meaning (progress, not time), the pace line (gone) and the Featured mark (see The Featured mark).

1. **Next tier after a minimum.** This spec puts a next tier in stage 2, above the horizon, so a tiered card's sun never sinks on the day its minimum is met (the brief had it in stage 1). The cost: as a tier nears, the band is nearly fully lit, then it crossfades back when the next target is further away. Happy with that? The alternative is to treat a tier on a card with no minimum as its gate.
2. **Ridge reading.** Level, where the gap shrinks with spend (specified)? Or literal, cumulative spend by day running on horizontally, which needs a Worker change and puts time back into the art?
3. **Calm cards.** Minimum met with no cap, highest tier and no cap all sit evenly lit with the sun just risen and no marker. Cards whose rewards are locked or withheld look the same, and only the slip says so. Should those be dimmer?
4. **Period track.** Add the optional thin labelled period track under the sheet's hero, or leave time to the deadline text and the Periods section?
5. **What the strip leaves out.** It drops today's chevron and does not take the web face's issuer and type caps line ("DBS · Miles"), to stay at today's height. Want either back? The caps line costs about 13pt per row.
6. **Register.** A paper row with a thumbnail print (specified), or the full strip, as on the Rewards tab?
7. **Earned.** The strip keeps the earned amount inside the basis line, as today. The web face shows it large in the corner. Should it be large on the phone too?
8. **Partial-block cap.** Leave the row as specified (fully lit with the raw figure, and the sheet explains blocks)? Or add "Within one block of the cap" to the row?
9. **Failed look.** A monochrome print with no sun (specified, which keeps text contrast)? Or the concept's milky fog, which needs different inks on fogged night skies?
10. **Day faces in dark mode.** Keep prints identical in both modes, as the web does today? Or dim day skies by about 10% in dark mode on both platforms?
11. **Fonts on iOS.** Bundle Instrument Serif and IBM Plex for the card only now (about 1.3 MB) and decide on app-wide use later?
12. **iPad.** Cap the rows at 640pt (specified), or lay strips out in a two-column grid at regular width?
13. **Zoom from row to sheet.** Try `matchedTransitionSource` with `.navigationTransition(.zoom)` on a device, and keep it only if the sheet keeps its content-height detent? Or stay with the plain sheet?
14. **An existing VoiceOver repeat.** Cards with no basis (Highest tier active, No cap, failed) speak the earned amount twice. Fix it in this change, with a failing test first, or leave it?
