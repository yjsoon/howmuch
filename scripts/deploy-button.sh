#!/usr/bin/env bash
# Deploy command for the Deploy to Cloudflare button (root wrangler.jsonc).
# Runs only on Cloudflare Workers Builds, in the deployer's own account. The
# owner's stacks deploy from apps/worker; see AGENTS.md.
set -euo pipefail

if [ "${WORKERS_CI:-}" != "1" ]; then
  echo "Refusing to deploy: this script runs only on Cloudflare Workers Builds for the Deploy to Cloudflare button." >&2
  echo "To self-host from your machine, follow docs/self-hosting.md. Owner deployments use the deploy:* scripts in apps/worker." >&2
  exit 1
fi

cd "$(dirname "$0")/.."
bun run --cwd apps/web build
# Apply migrations before deploying so new code never meets an old schema.
bunx wrangler d1 migrations apply DB --remote --config wrangler.jsonc
bunx wrangler deploy --config wrangler.jsonc
