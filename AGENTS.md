# HowMuch Agent Guidance

## Cloudflare deployments

- Deploy HowMuch only through Wrangler profile `yj`, Cloudflare account `YJ` (`810a0c404daff0737f4a2a97a7aab092`). This is the owner's personal Cloudflare account, referred to by the owner as `yjsoon@gmail.com`; Cloudflare currently reports its accepted Super Administrator member as `cloudflare@yjsoon.com`.
- Do not use the Tinkertanker Cloudflare account.
- Before running any remote D1 migration or Worker deployment, verify that Wrangler has selected account `YJ` (`810a0c404daff0737f4a2a97a7aab092`) and that the configured resources exist there. The account ID and resource IDs are authoritative; do not block deployment solely because Cloudflare displays `cloudflare@yjsoon.com` instead of the owner's `yjsoon@gmail.com` shorthand.
- The expected production resources are Worker `howmuch` and D1 database `howmuch-production` (`57dc5569-d639-44c1-bb9d-6214f43a43b8`).
- The expected preview resources are Worker `howmuch-preview` and D1 database `howmuch-preview` (`7ca818bd-7f04-4b9b-8a84-8c8f84a6a272`).
- Never create replacement Cloudflare resources or change bindings merely because Wrangler is authenticated to the wrong account. Switch to the correct account instead.
- Follow `docs/deployment.md` for migration, deployment, and verification order.
