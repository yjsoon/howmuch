# First-owner setup

A brand-new HowMuch database has no user. The first visitor creates the owner account; later visits sign in with the same username and password. Setup is a real form, not a hidden API.

## Sub-features

- `setup-form` shows **Set up HowMuch** with Username, Password, and Setup token.
- `setup-create` accepts `verifier` / `howmuch-verify-15` / `howmuch-verify-bootstrap` and lands on Ledger.
- `setup-reject-short-password` keeps **Create account** disabled while the password is under 15 characters.
- `ia-no-plan` after create or sign-in: heading Ledger, Primary navigation has no `Plan`, `API tokens`, or `Rewards import`, `{web_url}/plan` and `{web_url}/no-such-route` both land on Ledger, and page text has no `Ready to assign`.
- `signin-return` shows **Sign in to HowMuch** after sign out (setup is no longer offered).
- `signout` returns to the sign-in form and drops the session.

## How to get to it (user POV)

- Open `{web_url}` on a freshly launched instance (setup).
- Choose **Sign out**, then open `{web_url}` again (sign in).
- Reload `{web_url}` with no session cookie.
- After create or sign-in, open `{web_url}/plan` and `{web_url}/no-such-route`.

## Driving it with control-howmuch

Preconditions:

- `control-howmuch doctor` passes.
- `GET {api}/api/auth/status` has `setup_required: true` and `user: null`.
- No HowMuch session cookie in this browser profile.

- **Open setup.** Go to `{web_url}`. The heading is `Set up HowMuch` and the submit button is `Create account`.
- **Short password.** Fill Username `verifier` and Password `short`. `Create account` stays disabled. The page does not navigate.
- **Create owner.** Fill Username `verifier`, Password `howmuch-verify-15`, Setup token `howmuch-verify-bootstrap`. Choose `Create account`. The button reads `Please wait…`, then the shell appears with masthead `HowMuch` and heading `Ledger`. Title is `Ledger · Halation`.
- **Home IA.** `Primary navigation` has no link named `Plan`, `API tokens`, or `Rewards import`. `Settings` is in the sidebar footer. Open `{web_url}/plan`. Lands on Ledger. Open `{web_url}/no-such-route`. Lands on Ledger. Page text has no `Ready to assign`.
- **Confirm session.** `control-howmuch http GET /api/auth/status` still reports `setup_required: false` (token is not a browser session). Proof that a user exists: `control-howmuch http GET /v1/plans` returns plan id `local-plan` and name `HowMuch Demo`.
- **Sign out.** Choose `Sign out`. Heading becomes `Sign in to HowMuch`. There is no Setup token field.
- **Sign in.** Fill Username `verifier` and Password `howmuch-verify-15`. Choose `Sign in`. Ledger loads again.
- **Proof.** Screenshot the Ledger shell after create (`artifacts/first-owner-setup/all-accounts-after-setup.png`), the same shell after `/plan` (`artifacts/first-owner-setup/plan-redirects-home.png`), and the sign-in form after sign out (`artifacts/first-owner-setup/sign-in.png`). All show HowMuch identity. Primary navigation in the Ledger shots has no `Plan` link.

## Gotchas

- If the heading is already `Sign in to HowMuch`, this database has an owner. Do not call that setup. Cleanup and launch a new instance.
- `Create account` stays disabled until Username is non-empty, the password is ≥15 characters, and the setup token is non-empty (the verify stack always sets `HOWMUCH_API_TOKEN`, so the token field is present).
- scrypt is slow. Wait for Ledger, not a fixed 200ms sleep.
- Opening any app route without a session still renders the setup/sign-in form. That is not a routing bug.
- Do not POST `/api/auth/setup` from `control-howmuch http` and call the feature verified.
- iOS Connection cannot create the owner. Finish this recipe on `{web_url}` before any `ios-*` recipe.
