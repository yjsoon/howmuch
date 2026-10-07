# Settings

Settings is the home for account plumbing: change password, currency and date format (owners only), API tokens and Rewards import. Those tools are not top-level money-flow links.

## Sub-features

- `settings-open` opens the hub from **Settings** and from `/settings`.
- `settings-tokens` follows **API tokens** to the token page.
- `settings-rewards` follows **Rewards import** to the importer.
- `settings-not-primary` keeps **API tokens** and **Rewards import** out of Primary navigation.
- `settings-password` changes the password: the current session stays signed in on a rotated cookie, other sessions are signed out, personal API tokens keep working.
- `settings-formats` changes the plan currency and date format (owner only); amounts and dates repaint without a reload.
- `settings-crumb` returns to the hub from the `← Settings / …` breadcrumb on a tool page.

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
- **API tokens.** Choose `API tokens`. Title is `API tokens · HowMuch`. Breadcrumb is `← Settings / API tokens`. Choose `Settings` in the breadcrumb to return to the hub.
- **Rewards import.** From the hub, choose `Rewards import`. Title is `Rewards import · HowMuch`. Heading is `Rewards import`.
- **Change password.** In **Change password** enter the current password, a new one of 15 or more characters, and the same again. Short, mismatched or unchanged values show an inline alert; a wrong current password shows `Current password is incorrect`. Success shows `Password changed. This device stays signed in; every other session has been signed out.` The session cookie value changes. After ten wrong current passwords the alert reads `Too many attempts. Try again in 15 minutes.` A second browser context signed in earlier lands on the sign-in form at its next request.
- **Currency and date format.** Choose a new currency and/or date format, then `Save formats` (disabled until something changes). Date options read `Day first (24 May 2026)`, `Month first (May 24, 2026)` and `Year first (2026-05-24)`. The register and report date periods use that rendering; the default plan shows `24 May 2026`. Success shows `Formats saved.` with a note that the iOS app updates its currency on its next refresh and always shows `24 May 2026`. Register amounts and dates change straight away; `GET /v1/plans/{plan_id}/settings` shows the new values.
- **Proof.** Screenshot the hub (`artifacts/settings/hub.png`) and the All Accounts sidebar showing Settings in the footer, not above Reflect (`artifacts/settings/sidebar.png`).

## Gotchas

- Desktop Settings lives with Sign out in the sidebar footer. It is not a Primary navigation item.
- Viewport ≤720px hides that footer. Open **Open menu** and use the Settings link at the bottom of the drawer.
- Direct URLs `/api-tokens` and `/import/rewards` still work. They are not the hub.
