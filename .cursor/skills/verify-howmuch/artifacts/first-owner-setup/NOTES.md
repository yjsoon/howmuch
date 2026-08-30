Drove first-owner-setup on a fresh `control-howmuch` stack after Plan left the default web IA.

- `setup-form` and `setup-reject-short-password` passed.
- `setup-create` landed on `/transactions?range=all&accounts=all`.
  Heading `All Accounts`. Title `All Accounts · HowMuch`.
- `ia-no-plan`: Primary navigation has Scheduled, API tokens, Reflect reports, All Accounts, Organise accounts. No `Plan` link. `{web_url}/plan` and `{web_url}/no-such-route` both become All Accounts. Page text has no `Ready to assign`.
- `signout` showed `Sign in to HowMuch` with no Setup token field.
- `signin-return` loaded All Accounts again. Still no Plan link.

HTTP `GET /api/auth/status` is `setup_required: false`.
`GET /v1/plans` returns `local-plan` / HowMuch Demo.
The Bearer token is not a browser session, so `user` stays null.
