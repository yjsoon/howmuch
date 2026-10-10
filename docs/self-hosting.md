# Self-hosting Halation on Cloudflare

Halation runs as one Cloudflare Worker (web app and API on the same address) with one D1 database. This guide takes you from nothing to a working instance on your own Cloudflare account. It does not touch the owner's production deployment.

Self-hosting is the only way to run Halation on a server. There is no hosted service: the owner's instance is personal and does not take other users.

## Limits, stated plainly

- One instance serves one person or household. It is not multi-tenant.
- There is no public sign-up. Setup creates the first owner once; after that nobody can register.
- There is no budgeting. Categories are tags on transactions, used for reports and rewards rules.
- You operate it: you apply migrations, take backups and keep the Worker updated.
- The Bun and SQLite server (`bun run dev:stack`) is for local development only. It is not a supported way to self-host.

## One-click install

[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/yjsoon/howmuch)

The button sets up the same Worker and D1 database as the manual steps below, without a terminal.

1. You need a Cloudflare account on the Workers Paid plan (see [Costs](#costs)) and a GitHub or GitLab account.
2. Click the button. Cloudflare copies this repository into your GitHub or GitLab account, so updates you make later come from your copy.
3. On the setup page, name the repository, the Worker and the database, or keep the defaults.
4. For `HOWMUCH_API_TOKEN`, enter a long random value, for example the output of `openssl rand -hex 32`, and keep a copy in a password manager. It is your setup token (see [step 4](#4-create-the-setup-token)).
5. Deploy. Cloudflare creates the database, builds the web app, applies the database migrations and deploys the Worker, then shows its `workers.dev` address.
6. In the Cloudflare dashboard, open the Worker's **Settings**, then **Variables and Secrets**, and set `HOWMUCH_TIME_ZONE` to your IANA time zone, such as `Europe/London`. It starts as `UTC`.
7. Carry on from [first-owner setup](#5-first-owner-setup).

Scheduled transactions are entered daily at 00:05 UTC. To run them at your local midnight instead, change `triggers.crons` in `wrangler.jsonc` in your copy of the repository, as described in [step 2](#2-create-your-config).

Each push to your copy's main branch rebuilds and redeploys, applying any new migrations first. To update, bring the latest release tag from `yjsoon/howmuch` into your copy and push it. Your copy's `wrangler.jsonc` holds your database ID, so keep yours when the two differ. For backups, run the commands in [Backups](#backups) from the root of your copy with `--config wrangler.jsonc` and your database name.

The rest of this guide is the manual route, which gives you a local clone and full control of the config.

## Prerequisites

- A Cloudflare account with the Workers Paid plan (US$5 a month). See [Costs](#costs) for why the free Workers plan is not enough.
- [Bun](https://bun.sh) installed.
- Git and `openssl` (or any way to produce a long random string).

## 1. Get the code

```sh
git clone https://github.com/yjsoon/howmuch.git
cd howmuch
bun install
cd apps/worker
bunx wrangler login
```

`wrangler login` opens a browser to authorise Wrangler against your Cloudflare account. Check which account it selected with `bunx wrangler whoami` before going further.

## 2. Create your config

```sh
cp wrangler.self-host.example.jsonc wrangler.self-host.jsonc
```

`wrangler.self-host.jsonc` is gitignored, so your IDs stay out of the repository. Every command below passes `--config wrangler.self-host.jsonc` and runs from `apps/worker`.

Create the database and note the `database_id` it prints:

```sh
bunx wrangler d1 create <db-name> --config wrangler.self-host.jsonc
```

Choose any name for `<db-name>` and use it wherever this guide says "the database name you chose". Passing `--config` stops Wrangler reading another `wrangler.jsonc` in the repository. Wrangler may offer to add the D1 binding to your config for you; either accept or fill it in by hand as described next.

Then edit `wrangler.self-host.jsonc`:

- `name`: the Worker name (it becomes `<name>.<your-subdomain>.workers.dev`).
- `d1_databases[0].database_name` and `database_id`: from the `d1 create` output.
- `HOWMUCH_DEFAULT_PLAN_ID`: a new UUID, for example `bun -e "console.log(crypto.randomUUID())"`. Never change it after setup.
- `HOWMUCH_TIME_ZONE`: your IANA time zone, such as `Europe/London`.
- `triggers.crons`: the daily materialisation of due scheduled transactions. Cron uses UTC, so convert your local 00:05 (the example explains how).
- Optional: uncomment `routes` for a custom domain on a zone in your account. Without it, the `workers.dev` address works.

## 3. Create the schema and deploy

```sh
bunx wrangler d1 migrations apply <db-name> --remote --config wrangler.self-host.jsonc
bun run deploy:self-host
```

The deploy builds the web app and runs `wrangler deploy` with your config. Wrangler prints the address of your Worker. Deploy before creating the secret below, so the Worker already exists when the secret is added.

## 4. Create the setup token

```sh
openssl rand -hex 32
bunx wrangler secret put HOWMUCH_API_TOKEN --config wrangler.self-host.jsonc
```

Paste the random string when prompted. Keep a copy in a password manager: it is the setup token, and it also authorises default-plan integrations, so treat it like a password. Until this secret exists, setup fails closed.

## 5. First-owner setup

Open your Worker's address in a browser. The app shows the setup form. Enter a username, a password of at least 15 characters, and the setup token from step 4.

The form also asks for a currency and a date format, prefilled from your browser's language. That guess is only a guess: browsers often report US English whatever the person's country, so check both before you continue. You can change them later in Settings.

Setup works once. A second attempt returns "Setup has already completed".

### Changing the currency or date format afterwards

Sign in as the plan owner, open **Settings**, and use **Currency and date format**. Choose the new values and save; amounts and dates in the web app update straight away. Only owners see this section.

Changing the currency only changes the symbol and decimal places shown. Nothing is converted: $100 becomes £100. For a currency such as JPY the cents are hidden, not lost. The date options are orderings: day first (24 May 2026), month first (May 24, 2026) and year first (2026-05-24). The iOS app shows the new currency after its next refresh and always shows dates as 24 May 2026.

### Changing your password

Open **Settings** and use **Change password**. Enter the current password and the new one (at least 15 characters). Every other browser and device signed in as you is signed out; the one you used stays signed in (it is given a fresh session behind the scenes). Personal API tokens keep working, so revoke any you no longer trust on the **API tokens** page.

## 6. Connect the iOS app

The iOS app is not on the App Store. If you have a build, open **More, then Connection settings** on the Accounts, Rewards, Reflect or Assistant screen, and set the server URL to your Worker's `https://` address. Then sign in with the username and password you chose. The app never asks for the setup token, which is why first-owner setup happens in the browser.

## Updating

From the root of your clone, move to the latest release tag rather than the default branch, which may hold unreleased work:

```sh
cd <path-to-your-clone>
git fetch --tags
git checkout "$(git tag --list 'v*' --sort=-v:refname | head -n 1)"
bun install
cd apps/worker
bunx wrangler d1 migrations apply <db-name> --remote --config wrangler.self-host.jsonc
bun run deploy:self-host
```

Apply migrations before deploying so the new code never meets an old schema. Read the tag's commit log (`git log --oneline <previous-tag>..<new-tag>`) for anything that needs more than this.

## Backups

D1 keeps point-in-time history, but take your own copy before migrations and at least monthly:

```sh
mkdir -p ../../data/backups
bunx wrangler d1 export <db-name> --remote --output ../../data/backups/backup-$(date +%F).sql --config wrangler.self-host.jsonc
```

`data/` is gitignored. The file contains your financial data and password hashes: keep it private and never commit or share it.

## Costs

Expect to need the Workers Paid plan (US$5 a month). Password hashing (scrypt) takes roughly 200 ms of CPU for each sign-in and for setup, far above the 10 ms per-request CPU limit on Workers Free, so those requests fail there with a CPU-limit error. D1's free tier is enough for one household, but check Cloudflare's current limits and pricing yourself.
