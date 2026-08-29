Setup on `{web_url}` created `verifier` and landed on All Accounts
(`/transactions?range=all&accounts=all`, title `All Accounts · HowMuch`).

Plan still opened from Primary navigation (`/plan?range=all&accounts=all`).
HTTP `GET /api/auth/status` then reported `setup_required: false`.
The Bearer token is not a browser session, so `user` stayed null.
