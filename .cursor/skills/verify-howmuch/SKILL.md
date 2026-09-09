---
name: verify-howmuch
description: Drive HowMuch in a real browser (web ledger) and, for capture/intake/Shortcuts, in the iOS Simulator against an isolated local Bun/SQLite stack. Use when proving user-facing behaviour (first-owner setup, Reflect, register, quick entry, schedules, tokens, iOS Add Transaction, typed intake, App Intents) or after changing apps/web, apps/ios, the local API, or auth.
---

# Verify HowMuch

HowMuch has two user surfaces in this repo. Drive the one the change actually touched. Both talk to the same disposable local API from `control-howmuch launch`. Never point either at `howmuch.soon.sg`.

**Web** (`apps/web`) is the React ledger: first-owner setup, five Reflect reports (including Rewards), register, `/add` quick entry, schedules, tokens, sidebar accounts. There is no monthly Plan edit on the web.

**iOS** (`apps/ios`) is the SwiftUI companion: Accounts / Rewards / Reflect on iPhone, Plan and Assistant in trailing **More** (and in the iPad sidebar), a floating **Add Transactions** plus, the **Add Transaction** capture sheet, Duplicate for Today, and (when built) typed intake, the `N > 1` review list, Shortcuts App Intents, share, and the screenshot offer. Specs: `docs/frontend/intake-ui.md`, `docs/frontend/app-intents.md`. Issues: [#87](https://github.com/yjsoon/howmuch/issues/87), [#96](https://github.com/yjsoon/howmuch/issues/96) and their children.

Not covered here:

- Hosted Worker + D1. Do not run Wrangler deploys for this skill.
- YNAB Rewards Tracker (`yjsoon/ynab-rewards-tracker`) — not in this repo. HowMuch imports a settings export at **Rewards import** (`/import/rewards`) and shows the live dashboard at **Rewards** (`/rewards`) against the HowMuch ledger. There is no YNAB OAuth to drive.
- The clickable HTML prototype (`docs/frontend/intake-ui.html`). That is a layout draft. It is not the app. Never treat a prototype screenshot as proof that iOS meets a recipe.

There is no Playwright/Cypress harness. Drive web with Cursor browser / computer-use against the URL `control-howmuch state` prints. Drive iOS with computer-use against the Simulator. Use `control-howmuch http` as a second, read-only view of stored data.

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

Password must be at least 15 characters. Setup is scrypt; the form sits on "Please wait…" for a couple of seconds. **iOS never creates the owner.** Finish [First-owner setup](features/first-owner-setup.md) in the web app, then sign in from iOS Connection.

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

## iOS Simulator

Required for each selected `ios-*` recipe, not every recipe for every change. Skip those recipes (do not mark them verified via web `/add`) when Xcode / Simulator is missing. Continue safe local fixes and reruns within the task; validation does not authorize signing, publication, commits, pushes, or installing external skills.

1. `control-howmuch launch` and `doctor` pass. Complete first-owner setup on `{web_url}` if `setup_required` is still true.
2. Follow [apps/ios/AGENTS.md](../../../apps/ios/AGENTS.md) for canonical **HowMuch** simulator validation from the repo root. `scripts/ios-xcodebuild.sh test` reuses the selected iOS 26+ UDID, `build/xcode/DerivedData-simulator`, and successful products across build-for-testing and test-without-building; rebuild after source changes. No signing credentials or clean/pushed HEAD are needed.

Then install and launch the built app on that same simulator:

```sh
UDID="$(scripts/ios-xcodebuild.sh destination)"
xcrun simctl install "$UDID" "$(scripts/ios-xcodebuild.sh app-path)"
xcrun simctl launch "$UDID" sg.soon.howmuch
```

Computer-use drives the Simulator window, not `{web_url}`. This local installation does not prove or authorize physical-device distribution.

3. Connection (**More → Connection settings** on Accounts, Rewards, or Reflect):
   - **Server** = `{api_url}` from `control-howmuch state` (Simulator: `http://127.0.0.1:{api_port}`). New installs default to `https://howmuch.soon.sg` — change it. HTTP is allowed only for this device or this LAN.
   - **Username** `verifier`, **Password** `howmuch-verify-15`. Choose **Sign in**.
   - Plan becomes `HowMuch Demo` / `local-plan` automatically (only plan on this stack).
   - If the sheet says setup is required, you skipped web first-owner setup. Finish that, then **Retry Setup Check**. iOS has no Setup token field.

4. After sign-in, Accounts shows Everyday Account, Rainy Day Saver, Travel Card.

Do not paste a production token. Do not leave Server on `howmuch.soon.sg`. A Debug launch-environment bootstrap is production-only — do not use it for verify.

### Intake gate (shipped vs planned)

Check the running app, not the spec, before driving a planned recipe. If the handle is absent, report skip with the issue number. Do not call the HTML prototype or web `/add` a substitute.

| Recipe | Drive when |
| --- | --- |
| [iOS connection](features/ios-connection.md) | Connection sheet exists (always) |
| [iOS rewards](features/ios-rewards.md) | Rewards tab exists |
| [iOS rewards import](features/ios-rewards-import.md) | Connection **Rewards import** exists |
| [iOS add account](features/ios-add-account.md) | Accounts trailing plus **New Account** exists |
| [iOS edit account](features/ios-edit-account.md) | Accounts row **Edit Account** and register title editor exist |
| [iOS capture](features/ios-capture.md) | Add Transaction sheet exists (always). After #98, Duplicate / + / Quick Action share one door |
| [iOS capture typed replies](features/ios-capture-typed-replies.md) | Conversational Add Transactions on #153 (`29f42e7`). Darwin / Xcode. `typed-wait` already proven; drive `typed-reply-complete` with a remote AI provider, not on-device Foundation Models on HowMuch Verification |
| [iOS intake compose](features/ios-intake-compose.md) | A compose `TextField` sits above the amount header on Add Transaction (#99 / #102) |
| [iOS intake review list](features/ios-intake-review-list.md) | Two spends in one typed sentence open **{N} Transactions** (#103) |
| [iOS App Intents](features/ios-app-intents.md) | Shortcuts lists **Add Transaction** (#101). Catalog #100 is a precondition |
| [iOS share and screenshots](features/ios-share-and-screenshots.md) | Share target or Accounts offer exists (#104 / #106) |

Specs for expected chrome: `docs/frontend/intake-ui.md`, `docs/frontend/app-intents.md`. British copy. Markdown spec wins if the HTML still shows a mic or helper captions.

## Drive

Read `features/README.md`, then the feature file. Start from the baseline there unless a recipe says otherwise.

Web browser:

- Open `{web_url}` from `control-howmuch state`.
- Prefer visible names, `aria-label`s, and routes over CSS or coordinates.
- Viewport ≤720px hides the sidebar. Click the button named **Open menu** before any nav link.
- After setup, `document.title` is `{page} · HowMuch` (e.g. `All Accounts · HowMuch`).
- Demo rows are dated **2026-03-01 through 2026-05-24**. Default report/register windows follow today's calendar, so they are empty until you choose **All** or set From/To to that span.

iOS Simulator:

- Prefer tab titles, navigation titles, and accessibility labels over coordinates.
- Tab bar (iPhone): **Accounts**, **Rewards**, **Reflect**, plus a floating **Add Transactions** plus that opens capture and does not change the selected tab. Plan and Assistant are **More** menu items, not tabs. iPad regular-width sidebar lists Accounts, Rewards, Reflect, Plan, and Assistant.
- Capture title is **Add Transaction**. Leading **Cancel**. Trailing glass **Save** when the keypad is down. `canSave` is amount + account; payee is optional.
- Web `/add` is a different product. It does not prove iOS capture.

Stable web handles:

| Thing | Handle |
| --- | --- |
| First-run heading | `Set up HowMuch` |
| Later heading | `Sign in to HowMuch` |
| Auth fields | labels `Username`, `Password`, `Setup token` |
| Auth submit | `Create account` / `Sign in` |
| Primary nav | `nav` named `Primary navigation` |
| Nav links | `Scheduled`, Reflect reports (`Spending breakdown`, `Income v Spending`, `Net Worth`, `Age of Money`, `Rewards`), `All Accounts`, `Organise accounts` |
| Settings | sidebar footer link `Settings` (drawer bottom on viewport ≤720px). Hub lists `API tokens` and `Rewards import` |
| Quick entry | sidebar `+ Add transaction` or route `/add` |
| Register compose | account register toolbar `+ Add transaction` |
| Sign out | button `Sign out` |
| Date range | group `Date range`, buttons `This month`, `Last month`, `2M`, `3M`, `YTD`, `1Y`, `All` |
| Custom dates | `From date`, `To date` |
| Register search | searchbox `Search transactions` |

Stable iOS handles:

| Thing | Handle |
| --- | --- |
| Tabs | iPhone `Accounts`, `Rewards`, `Reflect`. iPad sidebar also `Plan`, `Assistant`. Floating plus `Add Transactions` |
| New account | Accounts trailing `New Account` (plus). Sheet title `New Account` |
| More | `More` (ellipsis). iPhone items `Plan`, `Assistant`, `Connection settings`. iPad regular: `Connection settings` only |
| Connection | `Connection settings` (inside More). Sheet title `Connection` |
| Server field | placeholder `http://192.168.1.10:8787` under header `Server` |
| Access | `Username`, `Password`, button `Sign in` / `Sign in again` |
| Sign out | `Sign out / Use another account` |
| Capture | floating plus `Add Transactions`, or home-screen Quick Action `Add Expense` |
| Capture title | `Add Transaction` (edit is `Transaction`) |
| Capture cancel | `Cancel` |
| Capture save | `Save` (hidden while keypad or compose is focused) |
| Amount direction | `Outflow` / `Inflow` |
| Detail rows | `Payee` (`Choose Payee`), `Category` (`Choose Category`), `Account` (`Choose Account`), `Date` |
| Duplicate | register row long-press / context menu `Duplicate for Today` |
| Ambiguous (planned) | footnote `Which account?` / `Which category?` in uncategorised ochre |
| Review list (planned) | title `{N} Transactions`, trailing `Add {n} to {account}` |
| Reading (planned) | title `Reading…`, caption `Stays on this device` |
| Shortcuts (planned) | `Add Transaction` / phrase `Add a transaction in HowMuch` |

HTTP second view (Bearer token from state, not a substitute for the UI path):

```sh
control-howmuch http GET "/v1/plans/local-plan/accounts"
control-howmuch http GET "/api/reports/spending-breakdown?plan_id=local-plan&from=2026-03-01&to=2026-05-31"
```

Do not POST `/api/auth/setup` or `/api/mobile/quick-entry` to "prove" a UI feature. Those skip the user path. Do not POST `/v1/plans/{id}/transactions` to "prove" iOS Save — iOS Save goes through the outbox, then that same POST. The user tap is the proof; HTTP is the side effect.

## Evidence

Write proof under `.cursor/skills/verify-howmuch/artifacts/<feature-id>/`. Cleanup must not delete this tree.

A proof is incomplete if it is only the last screen. Capture:

1. The action (setup form filled, `All` selected, payee typed, compose Return, Shortcuts run).
2. The resulting UI (`Saved.`, `Spending breakdown` with Groceries, register row visible, Add Transaction prefilled, review list).
3. A side effect: `control-howmuch http` JSON, or a second UI view of the same row.

Name files with the feature id and entry point, e.g. `spending-breakdown/all-range.png` and `spending-breakdown/report.json`.

Mocks are not used. The local API is the real ledger for this stack. Do not verify against production D1.

iOS mutations still prove via `control-howmuch http` against `{api_url}` after Save / Add. Also confirm the row on the iOS register (Everyday Account, today's date). A toast `Saved {amount} — {payee}` is not enough on its own.

Hard fails for intake / Shortcuts (do not call the recipe passing if any of these happen):

- The model or Shortcuts posts without the user tapping **Save** / **Add n to {account}**.
- Bytes or a transcript go to the HowMuch Worker (`/parse` must not exist; share must not upload).
- Confirmation is a chat thread.
- A custom mic is the v1 CTA.
- Compose is hidden only because the model is downloading (`.modelNotReady`).
- Trailing **Save** stays visible over the system QWERTY while compose is focused.
- A silent account/category pick when two live names match.
- Shortcuts `perform()` returns a saved transaction or writes the outbox.

## Cleanup

```sh
control-howmuch cleanup
```

Kills the recorded `howmuch-verify-*` tmux session and deletes `/tmp/howmuch-verify/<run-id>`. Leaves `.cursor/skills/verify-howmuch/artifacts/` alone. After cleanup, `ls` that artifacts directory and confirm the proof is still there.

Never `pkill bun`, `pkill vite`, or `tmux kill-session -t howmuch-dev`. Simulator can stay booted; do not point it at production after cleanup (Server would 404). Sign out of HowMuch in Simulator if you leave it running.

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
