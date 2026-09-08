# iOS connection

iOS talks to HowMuch over a stored Server URL and a Keychain session. First-owner setup happens on the website. Simulator verification points Server at the isolated API, signs in as `verifier`, and never uses production.

## Sub-features

- `ios-conn-default` on a fresh install shows Connection with Server defaulting to `https://howmuch.soon.sg`, not the verify API.
- `ios-conn-setup-required` against a database with no owner explains that setup must finish on the website and has no Setup token field.
- `ios-conn-sign-in` against a launched verify stack signs in as `verifier` and lands on Accounts with Everyday Account.
- `ios-conn-plan` selects the only plan (`HowMuch Demo` / `local-plan`) without asking.
- `ios-conn-sign-out` signs out and returns to Connection with no ledger rows.

## How to get to it (user POV)

- First launch of HowMuch in Simulator (Connection is forced until authenticated).
- Choose **More** (ellipsis) on Accounts, Rewards, or Reflect, then **Connection settings**.
- After **Sign out / Use another account**, Connection is the whole UI again.

## Driving it with control-howmuch

Preconditions:

- `control-howmuch doctor` passes.
- `{api_url}` is the value from `control-howmuch state` (Simulator uses `http://127.0.0.1:{api_port}`).
- First-owner setup is **not** done yet for `ios-conn-setup-required`. It **is** done for `ios-conn-sign-in`.
- Xcode Simulator is running HowMuch (`sg.soon.howmuch`). If Simulator is missing, skip this whole file.

- **Refuse production.** If Server still reads `https://howmuch.soon.sg`, change it to `{api_url}` before Sign in. Do not authenticate against production.
- **Setup required.** With `setup_required: true`, Connection heading is `Connection`. Header `Setup required`. Copy includes that the site does not have an account yet. There is no `Setup token` field. Button `Open HowMuch Setup in Browser` may be present; do not use it as the verify path. Finish setup on `{web_url}` instead ([First-owner setup](./first-owner-setup.md)). Choose `Retry Setup Check`. Setup section goes away.
- **Sign in.** Server `{api_url}`. Username `verifier`. Password `howmuch-verify-15`. Choose `Sign in`. Footer `Signed in successfully.` Then Accounts. Navigation title `Accounts`. Everyday Account, Rainy Day Saver, and Travel Card are listed.
- **HTTP match.** `control-howmuch http GET /api/auth/status` has `setup_required: false`. `control-howmuch http GET /v1/plans` includes `local-plan` / `HowMuch Demo`.
- **Sign out.** Connection settings → `Sign out / Use another account`. Ledger tabs are gone. Sign in is offered again.
- **Proof.** Screenshot Connection with Server set to the verify URL (`artifacts/ios-connection/connection.png`) and Accounts after sign-in (`artifacts/ios-connection/accounts.png`). HowMuch identity visible. Server host is `127.0.0.1`, not `howmuch.soon.sg`.

## Gotchas

- iOS never stores the bootstrap token. Creating the owner via Connection is not a path.
- HTTP is only for this device or this LAN. `http://127.0.0.1:{port}` is valid in Simulator. A public http host is refused.
- New installs default to production. Leaving that URL and signing in with `verifier` will fail or, worse, hit the real site. Always set Server from `control-howmuch state`.
- A leftover production Keychain token from a previous Simulator run is not this stack. Sign out, then sign in to `{api_url}`.
- Do not use a Debug launch-environment connection bootstrap. That path is production-only.
