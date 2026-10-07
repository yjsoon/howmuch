# Account basics E2E notes

Revision: `aaf15e5fae1f3873ece4dc93e954dc9e92c0c764` plus the uncommitted account-basics working tree on `feat/account-basics`.

## Setup

- Isolated stack from `control-howmuch launch` (Bun API + Vite, throwaway SQLite seeded from `fixtures/demo-ledger.json`, OS-assigned localhost ports). Synthetic credentials only: owner `verifier`, setup token from the recipe. No remote account touched.
- Driver: Playwright, Chromium (`/opt/pw-browsers/chromium-1194`), two separate browser contexts (A and B). Script kept outside the repo; every step is listed below and the raw log is `e2e-log.txt`.
- Pre-existing behaviour found first: the web app never read the plan's `date_format`, so dates always rendered as `24 May 2026`. This change makes `formatDate` (full dates) follow the plan format, so the register now shows `24/05/2026` for the default `DD/MM/YYYY`.

## Steps, expected, observed

| # | Step | Expected | Observed |
|---|------|----------|----------|
| 1 | Context A: first-owner setup (SGD, DD/MM/YYYY), then Context B signs in | Both signed in | Both signed in |
| 2 | A: open Settings | Change password section and Currency and date format section (owner) visible, selects prefilled | Both visible; prefill SGD and DD/MM/YYYY; `settings-light-desktop.png` |
| 3 | A: register before | `$` amounts, `24/05/2026` style dates | `register-before.png`, `$541,000.00`, `24/05/2026` |
| 4 | A: new password `short` | Blocked client side | Browser min-length message (15 characters) |
| 5 | A: new and confirm differ | Inline alert, no request | `The new password and its confirmation do not match.` |
| 6 | A: wrong current password | 401, generic message, A still signed in | `Current password is incorrect`; `password-error.png`; status call 200 |
| 7 | A: correct current, valid new | Success message | `Password changed. Other sessions have been signed out.`; `password-success.png` |
| 8 | A: reload | Still signed in | Stayed on Settings |
| 9 | B: reload | Signed out | Sign-in form (`context-b-signed-out.png`) |
| 10 | B: sign in with old password | Rejected | `Invalid username or password` |
| 11 | B: sign in with new password | Works | Signed in |
| 12 | A: Save formats disabled before any edit | Disabled | Disabled |
| 13 | A: GBP and YYYY-MM-DD, save | Success message | `Formats saved...` (`formats-success.png`) |
| 14 | A: register after | `£` amounts, `2026-05-24` dates | `register-after.png`: `£541,000.00`, `2026-05-24` |
| 15 | A: switch to EUR, save, navigate in-app without reload | `€` amounts | `€541,000.00`, `€850.00` |
| 16 | `GET /v1/plans/local-plan/settings` from B's session | New formats | `date_format YYYY-MM-DD`, `currency_format iso_code EUR`, flag names unchanged |
| 17 | 390px width | No horizontal scroll, sections readable | `settings-light-390.png` |

Dark mode: the web app has no dark theme (the sidebar is dark by design in light mode, and there is no `prefers-color-scheme` handling), so there is no separate dark rendering to check. The new sections reuse the existing `--paper`, `--ink`, `--rule` tokens and `status-panel` classes.

## Not covered in the browser

- Owner-only gating for editors and viewers in the UI (no second-user flow exists in the web app). The server side (403 for editor and viewer) is covered by the isolated test.
- iOS (no UI change in this PR).

## Isolated tests (`apps/api/tests/account-basics.test.ts`, SQLite and D1 backends)

Written before the implementation. Before: `0 pass, 12 fail` (routes returned 404; pruning left expired rows). After: `12 pass, 0 fail`. Full suite: `813 pass, 0 fail`.
