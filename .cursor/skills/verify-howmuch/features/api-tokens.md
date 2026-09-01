# API tokens

API tokens mints a personal bearer token for `/v1`. The secret is shown once. Revoke stops it.

## Sub-features

- `tokens-open` opens the page from **Settings** → **API tokens** and from `/api-tokens`.
- `tokens-empty` shows no active tokens on a fresh verify instance.
- `tokens-create` mints a named token and reveals it once.
- `tokens-revoke` moves that token to the revoked list.

## How to get to it (user POV)

- Choose **Settings** in the sidebar footer, then **API tokens**.
- Open `{web_url}/api-tokens`.
- Open `{web_url}/settings`, then **API tokens**.
- Follow **API documentation →** to `/docs` (read-only; not this recipe).

## Driving it with control-howmuch

Preconditions:

- `control-howmuch doctor` passes.
- Owner `verifier` is signed in.
- Use token name `Verify browser` so the row is unique.

- **Open page.** Choose `Settings`, then `API tokens`. Title is `API tokens · HowMuch`. Heading is `API tokens`. Breadcrumb is `← Settings / API tokens`. Choose `Settings` in the breadcrumb to return to the hub. Base URL code includes `/v1`. Empty copy is `No active tokens. Create one when an app needs direct access to HowMuch.` Primary navigation has no `API tokens` link.
- **Create.** Token name `Verify browser`. `Create token` is disabled while the name is blank. Choose `Create token`. Heading `Save this token now` appears. Field `New personal API token` is a non-empty secret. Active list is hidden until you dismiss.
- **Dismiss.** Choose `I’ve saved it`. Active tokens shows `Verify browser`.
- **Revoke.** Choose `Revoke`, then confirm `Revoke`. The name moves under `Revoked tokens (1)`.
- **HTTP match.** `control-howmuch http GET /api/auth/status` is not the token list. After create (before revoke), the UI is the proof; do not POST a token from `control-howmuch http` and call the page verified.
- **Proof.** Screenshot the active row after dismiss (`artifacts/api-tokens/active.png`). Do not save or commit the reveal panel; the secret is shown once.

## Gotchas

- The secret is shown once. Reload after dismiss cannot reveal it again.
- `Create token` stays disabled on a blank or whitespace name.
- `/docs` is public API documentation. It is a different page. Opening it is not token create.
- Personal tokens use the signed-in owner's plan permissions. The verify Bearer in `control-howmuch state` is the bootstrap API token, not a personal token from this page.
- **API tokens** is not in Primary navigation. Open **Settings** first, or go to `/api-tokens`.
