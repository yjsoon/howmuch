Drove first-owner-setup on a fresh `control-howmuch` stack.

- `setup-form` and `setup-reject-short-password` passed.
- `setup-create` landed on `/transactions?range=all&accounts=all`.
  Heading `All Accounts`. Title `All Accounts · HowMuch`.
- `signout` showed `Sign in to HowMuch` with no Setup token field.
- `signin-return` loaded All Accounts again.

HTTP `GET /api/auth/status` is `setup_required: false`.
`GET /v1/plans` returns `local-plan` / HowMuch Demo.
The Bearer token is not a browser session, so `user` stays null.
