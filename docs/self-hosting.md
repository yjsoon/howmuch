# Self-hosting Halation on Cloudflare

Halation runs as one Cloudflare Worker (web app and API on the same address) with one D1 database. This guide takes you from nothing to a working instance on your own Cloudflare account. It does not touch the owner's production deployment.

## Limits, stated plainly

- One instance serves one person or household. It is not multi-tenant.
- There is no public sign-up. Setup creates the first owner once; after that nobody can register.
- There is no budgeting. Categories are tags on transactions, used for reports and rewards rules.
- You operate it: you apply migrations, take backups and keep the Worker updated.
- The Bun and SQLite server (`bun run dev:stack`) is for local development only. It is not a supported way to self-host.

## Prerequisites

- A Cloudflare account (the free plan is enough to start).
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
bunx wrangler d1 create halation
```

Then edit `wrangler.self-host.jsonc`:

- `name`: the Worker name (it becomes `<name>.<your-subdomain>.workers.dev`).
- `d1_databases[0].database_name` and `database_id`: from the `d1 create` output.
- `HOWMUCH_DEFAULT_PLAN_ID`: a new UUID, for example `bun -e "console.log(crypto.randomUUID())"`. Never change it after setup.
- `HOWMUCH_TIME_ZONE`: your IANA time zone, such as `Europe/London`.
- `triggers.crons`: the daily materialisation of due scheduled transactions. Cron uses UTC, so convert your local 00:05 (the example explains how).
- Optional: uncomment `routes` for a custom domain on a zone in your account. Without it, the `workers.dev` address works.

## 3. Create the schema and the token

```sh
bunx wrangler d1 migrations apply halation --remote --config wrangler.self-host.jsonc
openssl rand -hex 32
bunx wrangler secret put HOWMUCH_API_TOKEN --config wrangler.self-host.jsonc
```

Paste the random string when prompted. Keep a copy in a password manager: it is the setup token, and it also authorises default-plan integrations, so treat it like a password.

## 4. Deploy

```sh
bun run deploy:self-host
```

This builds the web app and runs `wrangler deploy` with your config. Wrangler prints the address of your Worker.

## 5. First-owner setup

Open your Worker's address in a browser. The app shows the setup form. Enter a username, a password of at least 15 characters, and the setup token from step 3. The new plan takes its currency and date order from your browser's locale (for example GBP and day/month/year for `en-GB`); if the browser cannot say, it starts as SGD with day/month/year.

Setup works once. A second attempt returns "Setup has already completed".

## 6. Connect the iOS app

The iOS app is not on the App Store. If you have a build, open **More, then Connection settings** on the Accounts, Rewards, Reflect or Assistant screen, and set the server URL to your Worker's `https://` address. Then sign in with the username and password you chose. The app never asks for the setup token, which is why first-owner setup happens in the browser.

## Updating

```sh
git pull
bun install
cd apps/worker
bunx wrangler d1 migrations apply halation --remote --config wrangler.self-host.jsonc
bun run deploy:self-host
```

Apply migrations before deploying so the new code never meets an old schema. Check the release notes for anything that needs more than this.

## Backups

D1 keeps point-in-time history, but take your own copy before migrations and at least monthly:

```sh
bunx wrangler d1 export halation --remote --output halation-backup.sql --config wrangler.self-host.jsonc
```

The file contains your financial data and password hashes. Keep it private and never commit or share it.

## Costs

A single household will likely fit inside the Workers Free plan and the D1 free tier, but check Cloudflare's current limits yourself. Workers Free has a daily request cap, and D1's free tier has daily row-read and row-write caps; once a daily cap is reached, requests and D1 queries fail until the allowance resets. Free Workers also have a small per-request CPU limit, and password hashing is CPU-heavy. If setup or sign-in fails with a CPU-limit error, move to the Workers Paid plan, which has far higher limits.
