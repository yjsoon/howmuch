# Account basics E2E notes

Revision: `b41332b` plus the uncommitted review-fix working tree on `feat/account-basics`.

## Setup

- Isolated stack from `control-howmuch launch` (Bun API + Vite, throwaway SQLite seeded from `fixtures/demo-ledger.json`, OS-assigned localhost ports), cleaned up afterwards. Synthetic credentials only (owner `verifier`, recipe setup token). No remote account touched.
- Driver: Playwright with Chromium (`/opt/pw-browsers/chromium-1194`), two browser contexts (A and B). Raw log: `e2e-log.txt`. Run on a fresh stack so the default plan is SGD / `DD/MM/YYYY`.
- Stored date values name an ordering: `DD/MM/YYYY` renders `24 May 2026` (as on `origin/main`), `MM/DD/YYYY` renders `May 24, 2026`, `YYYY-MM-DD` renders `2026-05-24`.

## Steps, expected, observed

| # | Step | Expected | Observed |
|---|------|----------|----------|
| 1 | A: first-owner setup form, B signs in | Date options labelled with example renders | `Day first (24 May 2026)`, `Month first (May 24, 2026)`, `Year first (2026-05-24)`; both signed in |
| 2 | A: register with the default plan | `24 May 2026` | `24 May 2026` (`register-day-first.png`) |
| 3 | A: Net Worth (`/net-worth?range=all`) | Same ordering in `As at` | `AS AT 7 OCT 2026` (upper-cased by CSS) |
| 4 | A: Settings | Plain currency copy, labelled date options | `settings-desktop.png`; copy reads "Nothing is converted: $100 becomes £100. For a currency such as JPY the cents are hidden, not lost." |
| 5 | A: choose Month first, save | Success note mentions iOS; register `May 24, 2026` | Both as expected (`register-month-first.png`); Net Worth `AS AT OCT 7, 2026` (`net-worth-month-first.png`) |
| 6 | A: choose Year first, save | Register `2026-05-24` | As expected (`register-year-first.png`); Net Worth `AS AT 2026-10-07` |
| 7 | A: restore Day first, change password | Success says this device stays signed in | `Password changed. This device stays signed in; every other session has been signed out.` |
| 8 | A: session cookie before and after | Value changed | Changed (rotated) |
| 9 | A: reload; old cookie value against `/v1/user` | A still signed in; old value 401 | Stayed on Settings; old value returned 401 |
| 10 | B: reload | Signed out | Sign-in form (`context-b-signed-out.png`) |
| 11 | A: repeated wrong current passwords | Rate-limit copy | After 10 wrong attempts: `Too many attempts. Try again in 15 minutes.` (`password-rate-limited.png`) |
| 12 | 390px width | Readable, no horizontal scroll | `settings-390.png` |

Screenshots from the earlier revision (numeric dates) were removed as stale.

## Not covered in the browser

- Owner-only gating for editors and viewers, and the Settings load-error line (no way to make the account fetch fail without altering the stack). Server roles are covered by the isolated tests.
- Dark mode: the web app has no dark theme.
- iOS (no UI change; the engine bundle was regenerated and checks as up to date).

## Isolated tests (`apps/api/tests/account-basics.test.ts`, SQLite and D1)

New tests were written before each fix and failed first for the intended reason: the login race (200 and a live session instead of 401), rotation (no new token or cookie), login spam starving the change (429 instead of 200), the route budget (shared counter), `null` body (500 instead of 400) and D1 `upsertPlan` resetting formats. Final: `bun test` 823 pass, 0 fail.
