# HowMuch Agent Guidance

## Cloudflare deployments

- Deploy HowMuch only through the Cloudflare account associated with `yjsoon@gmail.com`. Do not use the Tinkertanker Cloudflare account.
- Before running any remote D1 migration or Worker deployment, verify that Wrangler has selected the `yjsoon@gmail.com` account and that the configured resources exist there.
- The expected production resources are Worker `howmuch` and D1 database `howmuch-production` (`57dc5569-d639-44c1-bb9d-6214f43a43b8`).
- The expected preview resources are Worker `howmuch-preview` and D1 database `howmuch-preview` (`7ca818bd-7f04-4b9b-8a84-8c8f84a6a272`).
- Never create replacement Cloudflare resources or change bindings merely because Wrangler is authenticated to the wrong account. Switch to the correct account instead.
- Follow `docs/deployment.md` for migration, deployment, and verification order.
