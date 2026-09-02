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

Share a signed HowMuch IPA to a registered iPhone via https://speedflight.dev when the device is not plugged into this Mac.

- Script: `scripts/speedflight.sh "<title>" "<notes>"`
- Gitignored config: `.env.speedflight` — `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY_PATH`, `SPEEDFLIGHT_SECRET`, `SPEEDFLIGHT_DEEP_LINK=howmuch://`
- Key file: `ASC_PRIVATE_KEY_PATH` (this Mac: `~/Dropbox/private_keys/AuthKey_$ASC_KEY_ID.p8`). App Store Connect **Team** Key, Admin or App Manager, belonging to the same team as `DEVELOPMENT_TEAM`.
- Ad hoc / Speedflight currently signs with T Krobot (`XL5JK4F896`) because that is where the ASC key and device list live. The previous Xcode team was Tinkertanker (`PQ6U5ESLN2`); webcredentials AASA lists both application identifiers.
- The page link is the install auth; do not post it publicly. The IPA only installs on devices in that team's ad hoc profile.
