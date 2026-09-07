# rewards-card-api proof

- Feature: native Rewards card writes (`POST`/`PATCH`/`DELETE /api/rewards/cards`, `PATCH /api/rewards/settings`)
- Entry points used: `control-howmuch http` against the disposable API. No web editor exists yet. Linux has no Simulator.
- Instance: `http://127.0.0.1:56187` (control-howmuch run `20260907T231348-6894`)
- Action: empty `GET /api/reports/rewards` on the demo span, 422 for missing and unknown `ynabAccountId`, `POST` Native Travel on Travel Card plus Native Cash on Everyday Account, `PATCH` earningRate to 2, `PATCH` milesValuation to 0.04 with a Cloud Sync phrase, then `DELETE` Native Travel.
- API result: report cards scored Travel Card miles at 1661.6 and Everyday cashback at 24.61. Snapshot settings stored `{ milesValuation: 0.04 }` with no Cloud Sync phrase. After delete, live cards were Native Cash only. A second delete returned 404.
- Side effect: JSON files in this directory. `GET /api/reports/rewards` median 0.9 ms and `POST /api/rewards/cards` median 6.6 ms on local SQLite (seven samples). Both sit under the 300 ms POST budget.
- Not proved: Add Card UI, iOS editor, hide-capped tiles. Those wait on the web and iOS manage PRs.
