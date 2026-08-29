---
name: verify-howmuch
description: Drive the HowMuch web ledger in a real browser against an isolated local Bun/SQLite stack. Use when proving user-facing behaviour (first-owner setup, Plan, reports, register, quick entry) or after changing apps/web, the local API, or auth.
---

# Verify HowMuch

HowMuch's primary surface is the React web app (`apps/web`). A user signs in, edits a monthly Plan, reads four Reflect reports, searches the register, and posts a quick entry. This skill drives that path in a browser against a disposable local API.

Secondary surfaces, not covered here:

- iOS (`apps/ios`) — Xcode / simulator only
- Hosted Worker + D1 — production/preview. Do not point verification at `howmuch.soon.sg` or run Wrangler deploys for this skill.

There is no Playwright/Cypress harness. Drive the UI with Cursor browser / computer-use against the URL `control-howmuch state` prints. Use `control-howmuch http` as a second, read-only view of stored data.

## Launch

From the repo root, with `bun` on `PATH` and `bun install` already done:

```sh
export PATH="$PWD/.cursor/skills/verify-howmuch/bin:$PATH"
control-howmuch launch
control-howmuch doctor
```

`launch` creates `/tmp/howmuch-verify/<run-id>/`, seeds `fixtures/demo-ledger.json` into a private SQLite file, and starts a tmux session named `howmuch-verify-<run-id>` with two windows:

- `api` — `bun run api:dev` on an OS-assigned localhost port
- `web` — Vite on an OS-assigned localhost port, `HOWMUCH_API_URL` pointed at that API

Ready when `control-howmuch doctor` prints `ok` lines, including `ok health={"ok":true}` and `ok web_title=HowMuch`. `launch` already waits for `/health` and the Vite HTML shell.

Do not use `bun run dev`, `bun run dev:stack`, or tmux session `howmuch-dev`. Those own the shared `data/howmuch.sqlite` on ports 8787/5173. If doctor would have to attach to that instance, stop and launch a disposable one instead.

Two verification stacks can run side by side (different run ids, ports, and databases). `launch` refuses if `/tmp/howmuch-verify/current` already points at a healthy instance — `cleanup` first, or drive the one that is up.

Fixed disposable credentials (not production secrets):

| Field | Value |
| --- | --- |
| Username | `verifier` |
| Password | `howmuch-verify-15` |
| Setup token | `howmuch-verify-bootstrap` |
| Plan id | `local-plan` |

Password must be at least 15 characters. Setup is scrypt; the form sits on "Please wait…" for a couple of seconds.

Teardown: `control-howmuch cleanup`. It kills only the `howmuch-verify-*` session recorded in state. It never touches `howmuch-dev` or proof artifacts.

## Doctor

Read-only. Run this first whenever anything looks off:

```sh
control-howmuch doctor
```

It must report:

- tmux session `howmuch-verify-*` still running (never `howmuch-dev`)
- SQLite path inside `/tmp/howmuch-verify/<run-id>/`, never `data/howmuch.sqlite`
- `GET {api}/health` → `{"ok":true}`
- `GET {api}/api/auth/status` reachable
- `GET {web}/` HTML title `HowMuch`

`control-howmuch state` prints the URLs, ports, db path, and credentials. If doctor fails, cleanup and launch again. Do not "fix" it by talking to 8787/5173.

## Drive

Read `features/README.md`, then the feature file. Start from the baseline there unless a recipe says otherwise.

Browser:

- Open `{web_url}` from `control-howmuch state`.
- Prefer visible names, `aria-label`s, and routes over CSS or coordinates.
- Viewport ≤720px hides the sidebar. Click the button named **Open menu** before any nav link.
- After setup, `document.title` is `{page} · HowMuch` (e.g. `Plan · HowMuch`).
- Demo rows are dated **2026-03-01 through 2026-05-24**. Default report/register windows follow today's calendar, so in 2026-08 they are empty until you choose **All** or set From/To to that span.

Stable handles:

| Thing | Handle |
| --- | --- |
| First-run heading | `Set up HowMuch` |
| Later heading | `Sign in to HowMuch` |
| Auth fields | labels `Username`, `Password`, `Setup token` |
| Auth submit | `Create account` / `Sign in` |
| Primary nav | `nav` named `Primary navigation` |
| Plan / reports / register | links `Plan`, `Spending breakdown`, `Income v Spending`, `Net Worth`, `Age of Money`, `All Accounts` |
| Quick entry | `+ Add transaction` or route `/add` |
| Sign out | button `Sign out` |
| Date range | group `Date range`, buttons `This month`, `Last month`, `2M`, `3M`, `YTD`, `1Y`, `All` |
| Custom dates | `From date`, `To date` |
| Register search | searchbox `Search transactions` |
| Plan month | group `Plan month`, buttons `Previous month` / `Next month` / `Current` |
| Assignment | button `Edit assigned amount for {Category}` |

HTTP second view (Bearer token from state, not a substitute for the UI path):

```sh
control-howmuch http GET "/v1/plans/local-plan/accounts"
control-howmuch http GET "/api/reports/spending-breakdown?plan_id=local-plan&from=2026-03-01&to=2026-05-31"
```

Do not POST `/api/auth/setup` or `/api/mobile/quick-entry` to "prove" a UI feature. Those skip the user path.

## Evidence

Write proof under `.cursor/skills/verify-howmuch/artifacts/<feature-id>/`. Cleanup must not delete this tree.

A proof is incomplete if it is only the last screen. Capture:

1. The action (setup form filled, `All` selected, payee typed).
2. The resulting UI (`Saved.`, `Spending breakdown` with Groceries, register row visible).
3. A side effect: `control-howmuch http` JSON, or a second UI view of the same row.

Name files with the feature id and entry point, e.g. `spending-breakdown/all-range.png` and `spending-breakdown/report.json`.

Mocks are not used. The local API is the real ledger for this stack. Do not verify against production D1.

## Cleanup

```sh
control-howmuch cleanup
```

Kills the recorded `howmuch-verify-*` tmux session and deletes `/tmp/howmuch-verify/<run-id>`. Leaves `.cursor/skills/verify-howmuch/artifacts/` alone. After cleanup, `ls` that artifacts directory and confirm the proof is still there.

Never `pkill bun`, `pkill vite`, or `tmux kill-session -t howmuch-dev`.

## Helpers

```sh
export PATH="$PWD/.cursor/skills/verify-howmuch/bin:$PATH"
control-howmuch launch
control-howmuch doctor
control-howmuch state
control-howmuch http GET /health
control-howmuch cleanup
```

`bin/control-howmuch` is executable. If `bun` is missing: install it, then `bun install` at the repo root.
