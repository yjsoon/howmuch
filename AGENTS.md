# HowMuch Agent Guidance

## Task boundaries

- For implementation and validation tasks, continue task-scoped local fixes, builds, tests, and reruns through relevant verification. Preserve unrelated work; a failed check is not a reason to stop when a safe local fix is within scope.
- Read the relevant implementation and guidance, not the whole repository. Verify the affected behavior and representative UI states; documentation-only changes do not require app builds or every feature recipe.
- Commit only when requested, honoring the requested scope and message. Commit permission does not imply push permission. Do not infer permission to merge, change an exact requested revision, sign/provision, publish builds, deploy, or install/publish external skills.
- Read-only requests stay read-only. Exact-revision validation must report failures on that revision, not silently include fixes or substitute newer code.

## Cloudflare deployments

- Remote migrations and deployments require explicit authorization for the target environment. Deploy HowMuch only through Wrangler profile `yj`, Cloudflare account `YJ` (`810a0c404daff0737f4a2a97a7aab092`). This is the owner's personal Cloudflare account, referred to by the owner as `yjsoon@gmail.com`; Cloudflare currently reports its accepted Super Administrator member as `cloudflare@yjsoon.com`.
- Do not use the Tinkertanker Cloudflare account.
- Before running any remote D1 migration or Worker deployment, verify that Wrangler has selected account `YJ` (`810a0c404daff0737f4a2a97a7aab092`) and that the configured resources exist there. The account ID and resource IDs are authoritative; do not block deployment solely because Cloudflare displays `cloudflare@yjsoon.com` instead of the owner's `yjsoon@gmail.com` shorthand.
- The expected production resources are Worker `howmuch` and D1 database `howmuch-production` (`57dc5569-d639-44c1-bb9d-6214f43a43b8`).
- The expected preview resources are Worker `howmuch-preview` and D1 database `howmuch-preview` (`7ca818bd-7f04-4b9b-8a84-8c8f84a6a272`).
- Never create replacement Cloudflare resources or change bindings merely because Wrangler is authenticated to the wrong account. Switch to the correct account instead.
- Follow `docs/deployment.md` for migration, deployment, and verification order.

## iOS validation and publication

- Safe local builds/tests use `scripts/ios-xcodebuild.sh` and the [iOS validation contract](apps/ios/AGENTS.md). They do not require a clean/pushed HEAD, signing secrets, or an update to `main`. Unsigned compilation is not physical-device installation evidence.
- Speedflight is signed archive, export, and external publication in one command, not a validation step. Run it only for an explicitly authorized publication, following [the Speedflight runbook](docs/speedflight.md). iOS work alone does not authorize it.
- Preserve Apple team **Tinkertanker `PQ6U5ESLN2`**, bundle **`sg.soon.howmuch`**, and registered-device/signing blockers. Never substitute unsigned archives or change teams to bypass a blocker.
- Install-page links are private bearer credentials: share only in the authorized private chat, never PRs/issues/public logs. Do not install an external skill or trigger CI as a fallback without an explicit request.
