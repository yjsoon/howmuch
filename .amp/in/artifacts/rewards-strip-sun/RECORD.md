# Rewards strip: the phone cut of the sun

- Revision: the commit this folder lands in (branch `claude/project-thread-kqxlz2`), against `main` at 82afb83.
- Stack: `control-howmuch launch` (disposable Bun/SQLite stack seeded with `fixtures/demo-ledger.json`), owner `verifier` created through the setup form.
- Fixture: 13 synthetic cards imported through Settings → Rewards import (a Rewards Tracker export, every card on `acct-credit`): gate cards at fills 0.30, 0.63, 0.87, 0.96 and 0.98, a climb from 0 and one past a tier, a capped card, rest, calm, failed and a two-line name.
- Steps: Playwright (headless Chromium, 390 × 844 at 3x, reduced motion) opens `/rewards?to=2026-05-24`, sets `html[data-mode]` to dark and then light, and screenshots every `.rw-card`.
- Expected: no hairline marker on the strip; a 10px half-sun sitting on the horizon while it rides, lifting clear from 0.85; one smooth glow with no clipped arcs; no unlit 4% sliver at the right edge on cards at 0.96 and 0.98.
- Observed: as expected in both modes. `before-after-dark.png` and `before-after-light.png` show the first cut (left) against this one (right) for the 0.96 and 0.30 gate cards, the climb past a tier, the capped card, the two-line name and a resting miles card.
- `bun test` (883 pass) and `bun run build` in `apps/web` pass on this revision. iOS compiled separately (see the PR).
