# HowMuch Agent Guidance

## Task boundaries

- For implementation and validation tasks, continue task-scoped local fixes, builds, tests, and reruns through relevant verification. Preserve unrelated work; a failed check is not a reason to stop when a safe local fix is within scope.
- Read the relevant implementation and guidance, not the whole repository. Verify the affected behavior and representative UI states; documentation-only changes do not require app builds or every feature recipe.
- Commit only when requested, honoring the requested scope and message. Commit permission does not imply push permission. Do not infer permission to merge, change an exact requested revision, sign/provision, publish builds, deploy, or install/publish external skills.
- Read-only requests stay read-only. Exact-revision validation must report failures on that revision, not silently include fixes or substitute newer code.

## Cloudflare deployments

HowMuch's primary stack runs in the Tinkertanker Cloudflare account at
`https://howmuch.tk.sg`. The legacy stack in the owner's personal account now
serves only a permanent 308 redirect from `https://howmuch.soon.sg`, and its
D1 database is kept as a frozen cold backup. The `soon.sg` zone (including its
Cloudflare Email Routing) stays in the YJ account — do not move it.

### Primary stack (profile `tinkertanker`, account `Tinkertanker`)

- Wrangler profile `tinkertanker`, Cloudflare account `Tinkertanker` (`b8b1032c61d9475cd00229c74db7ec72`). Deploy with `bun run deploy:tk` from `apps/worker`, which pins `--env tk --profile tinkertanker`.
- The expected resources are Worker `howmuch` (env `tk` in `wrangler.jsonc`) and D1 database `howmuch-production` (`df039dbc-6dda-4150-9dc3-5854a8ca6818`; primary placed at KIX/Osaka at creation — see issue #183 and the creation rule in `docs/deployment.md`), serving `https://howmuch.tk.sg` (web front-end and API on one hostname).
- The `tk` environment has one cron, `5 16 * * *` (00:05 Asia/Singapore), which materialises due scheduled transactions. It has no YNAB configuration. `HOWMUCH_API_TOKEN` is an encrypted secret on this Worker.
- Do not add `HOWMUCH_REDIRECT_TARGET` to the `tk` env. Wrangler warns that top-level vars are not inherited; that warning is expected, and setting the var here would make production redirect to itself.
- Production deploys automatically when a `v*` tag is pushed (`.github/workflows/deploy.yml`), using the `CLOUDFLARE_API_TOKEN` repo secret pinned to this account. The workflow deploys only and never applies D1 migrations; migrations follow the order in `docs/deployment.md` and are run manually before tagging.
- This is the only environment that accepts writes. The iOS app's `productionBaseURL` points at `howmuch.tk.sg`; installs still carrying the former `howmuch.soon.sg` default migrate on launch, and the legacy `soon.sg` host stays reachable as a redirect.

### Legacy redirect + backup (profile `yj`, account `YJ`)

- Wrangler profile `yj`, Cloudflare account `YJ` (`810a0c404daff0737f4a2a97a7aab092`). This is the owner's personal Cloudflare account, referred to by the owner as `yjsoon@gmail.com`; Cloudflare currently reports its accepted Super Administrator member as `cloudflare@yjsoon.com`.
- Worker `howmuch` (top-level env in `wrangler.jsonc`) redirects every request to `https://howmuch.tk.sg` via `HOWMUCH_REDIRECT_TARGET` (308, path and query preserved). It has no cron and serves no data.
- D1 database `howmuch-production` (`57dc5569-d639-44c1-bb9d-6214f43a43b8`) holds the final production snapshot taken at the 2026-09-11 cutover, frozen read-only. Treat it as a cold backup: never write to it. Restoring from it means re-importing into the Tinkertanker database using the chunked procedure in `docs/deployment.md`.
- The preview environment still lives here: Worker `howmuch-preview` and D1 `howmuch-preview` (`7ca818bd-7f04-4b9b-8a84-8c8f84a6a272`), deployed with `bun run deploy:preview`.
- The `soon.sg` zone, its DNS, and its Email Routing live here and must stay here.

### Rules for both

- Before running any remote D1 migration or Worker deployment, verify that Wrangler has selected the intended account (`Tinkertanker` or `YJ`, IDs above) and that the configured resources exist there. The account ID and resource IDs are authoritative; do not block deployment solely because Cloudflare displays `cloudflare@yjsoon.com` instead of the owner's `yjsoon@gmail.com` shorthand.
- Never create replacement Cloudflare resources or change bindings merely because Wrangler is authenticated to the wrong account. Switch to the correct account instead.
- Run `scripts/backup-d1.sh` at least monthly and before any D1 migration (see `docs/deployment.md`). Dumps and checksums stay in gitignored `data/backups/`; the repository is public, so never commit them, upload them to GitHub releases or artifacts, or paste them anywhere world-readable. Restore is the manual chunked procedure, not a single command.
- Follow `docs/deployment.md` for migration, deployment, and verification order.

## iOS validation and publication

- Safe local builds/tests use `scripts/ios-xcodebuild.sh` and the [iOS validation contract](apps/ios/AGENTS.md). They do not require a clean/pushed HEAD, signing secrets, or an update to `main`. Unsigned compilation is not physical-device installation evidence.
- Speedflight is signed archive, export, and external publication in one command, not a validation step. Run it only for an explicitly authorized publication, following [the Speedflight runbook](docs/speedflight.md). iOS work alone does not authorize it.
- Preserve Apple team **Tinkertanker `PQ6U5ESLN2`**, bundle **`sg.soon.howmuch`**, and registered-device/signing blockers. Never substitute unsigned archives or change teams to bypass a blocker.
- Install-page links are private bearer credentials: share only in the authorized private chat, never PRs/issues/public logs. Do not install an external skill or trigger CI as a fallback without an explicit request.
