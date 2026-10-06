# Settings

Settings is the home for account plumbing (API tokens, Rewards import and the other tools) and for **Appearance**: the look (Dusk Ridge, Ridge Charcoal, Overexposed) and colour mode, saved on this device. Those tools are not top-level money-flow links.

## Sub-features

- `settings-open` opens the hub from **Settings** and from `/settings`.
- `settings-tokens` follows **API tokens** to the token page.
- `settings-rewards` follows **Rewards import** to the importer.
- `settings-not-primary` keeps **API tokens** and **Rewards import** out of Primary navigation.
- `settings-appearance` switches the look and the colour mode (**Match system**, **Light**, **Dark**). The choice is kept in this browser (`localStorage["howmuch.theme.v1"]`) across reloads and sign-out.
- `settings-crumb` returns to the hub from the `← Settings / …` breadcrumb on a tool page.

## How to get to it (user POV)

- Choose **Settings** in the sidebar footer (desktop).
- Open **Open menu**, then **Settings** in the drawer footer, under the accounts (viewport ≤720px).
- Open `{web_url}/settings`.

## Driving it with control-howmuch

Preconditions:

- `control-howmuch doctor` passes.
- Owner `verifier` is signed in.

- **Open hub.** Choose `Settings`. Title is `Settings · Halation`. Heading is `Settings`. The tools list has `API tokens` and `Rewards import`.
- **Appearance.** Section `Appearance` (meta `Saved on this device`) is a radio group of `Dusk Ridge` (marked `· default`), `Ridge Charcoal` and `Overexposed`, then group `Colour mode` with `Match system`, `Light` and `Dark` (`aria-pressed` marks the current one). Choose `Ridge Charcoal`: the page cross-fades and `document.documentElement.dataset.theme` is `ridge-charcoal`. Reload: it is still selected. Choose `Dusk Ridge` to restore the default.
- **Primary nav.** `Primary navigation` has `Ledger`, `Scheduled`, `Rewards` and the `Reports` group. It has no `API tokens` link and no `Rewards import` link.
- **API tokens.** Choose `API tokens`. Title is `API tokens · Halation`. Breadcrumb is `← Settings / API tokens`. Choose `Settings` in the breadcrumb to return to the hub.
- **Rewards import.** From the hub, choose `Rewards import`. Title is `Rewards import · Halation`. Heading is `Rewards import`.
- **Proof.** Screenshot the hub with the Appearance picker (`artifacts/settings/hub.png`) and the Ledger sidebar showing Settings in the footer, not in Primary navigation (`artifacts/settings/sidebar.png`).

## Gotchas

- Desktop Settings lives with Sign out in the sidebar footer. It is not a Primary navigation item.
- On a viewport ≤720px, open **Open menu**: the drawer carries the accounts and the footer, so Settings and Sign out are at its bottom.
- The theme is per device, not ledger data. Signing out keeps it.
- Direct URLs `/api-tokens` and `/import/rewards` still work. They are not the hub.
