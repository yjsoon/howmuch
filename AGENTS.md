# HowMuch Agent Guidance

## Cloudflare deployments

- Deploy HowMuch only through Wrangler profile `yj`, Cloudflare account `YJ` (`810a0c404daff0737f4a2a97a7aab092`). This is the owner's personal Cloudflare account, referred to by the owner as `yjsoon@gmail.com`; Cloudflare currently reports its accepted Super Administrator member as `cloudflare@yjsoon.com`.
- Do not use the Tinkertanker Cloudflare account.
- Before running any remote D1 migration or Worker deployment, verify that Wrangler has selected account `YJ` (`810a0c404daff0737f4a2a97a7aab092`) and that the configured resources exist there. The account ID and resource IDs are authoritative; do not block deployment solely because Cloudflare displays `cloudflare@yjsoon.com` instead of the owner's `yjsoon@gmail.com` shorthand.
- The expected production resources are Worker `howmuch` and D1 database `howmuch-production` (`57dc5569-d639-44c1-bb9d-6214f43a43b8`).
- The expected preview resources are Worker `howmuch-preview` and D1 database `howmuch-preview` (`7ca818bd-7f04-4b9b-8a84-8c8f84a6a272`).
- Never create replacement Cloudflare resources or change bindings merely because Wrangler is authenticated to the wrong account. Switch to the correct account instead.
- Follow `docs/deployment.md` for migration, deployment, and verification order.

## iOS Speedflight (ad hoc OTA)

When this session is on a Mac with Xcode, and the user wants HowMuch on a physical iPhone that is not plugged in (or after iOS work worth installing), cut a Speedflight build. Do not wait to be asked if that is clearly the handoff. Follow the Speedflight skill if it is installed (`~/.agents/skills/speedflight` or `npx skills add jakemor/speedflight`). This repo's pipeline is `scripts/speedflight.sh`.

Do **not** run it on Linux, a cloud VM without Xcode, or a Mac missing the checks below. GitHub Actions Speedflight is only if the user asks.

### Preflight (do this before the script)

Confirm, without printing secrets:

1. `uname` is Darwin and `xcodebuild -version` works.
2. Gitignored `.env.speedflight` exists at the repo root and defines `ASC_KEY_ID`, `ASC_ISSUER_ID` (not `ASC_ISSSUER_ID`), `ASC_PRIVATE_KEY_PATH`, `SPEEDFLIGHT_SECRET`, `SPEEDFLIGHT_DEEP_LINK=howmuch://`, `SPEEDFLIGHT_AUTHOR`.
3. The `.p8` at `ASC_PRIVATE_KEY_PATH` exists and is mode `600`. On this Mac it is `~/Dropbox/private_keys/AuthKey_TinkertankerAdmin_K3832HFK5M.p8` (key id `K3832HFK5M`). The script's default `~/private_keys/AuthKey_$ASC_KEY_ID.p8` is the wrong path here.
4. That key belongs to **Tinkertanker** `PQ6U5ESLN2`, which already owns bundle id `sg.soon.howmuch`. Check with `asc auth login` + `asc bundle-ids` (`seedId` / identifier). A T Krobot (`XL5JK4F896`) key authenticates but cannot register or sign this bundle id — do not change `DEVELOPMENT_TEAM` to make a wrong-team key work.
5. Working tree is clean and `HEAD` is pushed. The script refuses otherwise. Commit and push first (including any Release-only compile fixes; whole-module optimisation requires explicit `return` in multi-statement getters).

`DVTDeveloperAccountManager` / missing `Xcode-Token` for the Apple ID is noise if the three `-authenticationKey*` flags are passed. Cloud signing uses the `.p8`, not the Xcode GUI account.

### If the Mac is not set up

Tell the user which check failed and how to fix it. Do not archive unsigned, do not switch team, and do not create certificates or profiles by hand.

| Gap | What to tell them |
|---|---|
| Not Darwin / no Xcode | Speedflight has to run on this Mac (or they must explicitly ask for GitHub Actions). Simulator `CODE_SIGNING_ALLOWED=NO` is not a substitute. |
| No `.env.speedflight` or empty `SPEEDFLIGHT_SECRET` | Recreate the gitignored file; mint `SPEEDFLIGHT_SECRET` with `openssl rand -hex 24`. Keep `SPEEDFLIGHT_DEEP_LINK=howmuch://`. |
| Missing/empty `ASC_KEY_ID` or `ASC_ISSUER_ID` | App Store Connect → Users and Access → Integrations → App Store Connect API. **Switch the header team to Tinkertanker** first (Issuer ID is per team). Create a Team Key, Admin or App Manager. Key ID is the 10-character id; Issuer ID is the UUID at the top of that page. |
| Missing `.p8` | The `.p8` downloads once. Save as `~/Dropbox/private_keys/AuthKey_TinkertankerAdmin_<KEY_ID>.p8`, `chmod 600`, set `ASC_PRIVATE_KEY_PATH`. |
| `.p8` is `644` | `chmod 600` the key file. |
| Key's `seedId` is not `PQ6U5ESLN2` | Wrong team. Generate a new Team Key with Tinkertanker selected. Keep any T Krobot key for TK apps only. |
| Bundle id "not available" | They tried to sign `sg.soon.howmuch` with a non-Tinkertanker team. Revert `DEVELOPMENT_TEAM` to `PQ6U5ESLN2`. |
| Device will not install | Ad hoc IPA only runs on UDIDs in the Tinkertanker profile. Being registered on T Krobot does not count. They must add the iPhone to Tinkertanker, or plug it in once after the Tinkertanker key works. |

### Share a build

```sh
scripts/speedflight.sh "<one-line title>" "<what changed and what to test>"
```

Post `Build page: https://speedflight.dev/a/<pageId>` in the chat as a plain URL on its own line. That link is the install auth: Get in Safari on a Tinkertanker-registered iPhone. Never put it in the PR, issues, or other public text. Never print `SPEEDFLIGHT_SECRET`. Do not share a URL that includes a build id after the page id.
