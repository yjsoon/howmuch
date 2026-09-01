# Settings

Settings is the home for account plumbing: API tokens and Rewards import. Those tools are not top-level money-flow links.

## Sub-features

- `settings-open` opens the hub from **Settings** and from `/settings`.
- `settings-tokens` follows **API tokens** to the token page.
- `settings-rewards` follows **Rewards import** to the importer.
- `settings-not-primary` keeps **API tokens** and **Rewards import** out of Primary navigation.

## How to get to it (user POV)

- Choose **Settings** in the sidebar footer (desktop).
- Open **Open menu**, then **Settings** at the bottom of the drawer (viewport ≤720px).
- Open `{web_url}/settings`.

## Driving it with control-howmuch

Preconditions:

- `control-howmuch doctor` passes.
- Owner `verifier` is signed in.

- **Open hub.** Choose `Settings`. Title is `Settings · HowMuch`. Heading is `Settings`. The tools list has `API tokens` and `Rewards import`.
- **Primary nav.** `Primary navigation` has `Scheduled` and the Reflect reports. It has no `API tokens` link and no `Rewards import` link.
- **API tokens.** Choose `API tokens`. Title is `API tokens · HowMuch`. Eyebrow `Settings` returns to the hub.
- **Rewards import.** From the hub, choose `Rewards import`. Title is `Rewards import · HowMuch`. Heading is `Rewards import`.
- **Proof.** Screenshot the hub (`artifacts/settings/hub.png`) and the All Accounts sidebar showing Settings in the footer, not above Reflect (`artifacts/settings/sidebar.png`).

## Gotchas

- Desktop Settings lives with Sign out in the sidebar footer. It is not a Primary navigation item.
- Viewport ≤720px hides that footer. Open **Open menu** and use the Settings link at the bottom of the drawer.
- Direct URLs `/api-tokens` and `/import/rewards` still work. They are not the hub.
