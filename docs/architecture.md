# Architecture

- `apps/api`: shared domain/HTTP code, local SQLite repository, D1 atomic repository and async reports.
- `apps/worker`: D1-only Worker composition and assets for the cut-over runtime.
- `apps/web`: React client.

Local development remains Bun/SQLite. Hosted storage is D1 only. The production YNAB import is a lossless, read-only source mirror; HowMuch changes category assignments, targets, and imported schedules through separate local overlays, and stores new schedules as HowMuch-owned rows. D1 mutations are preplanned atomic batches guarded by write versions, immutable command receipts, SQL assertions, and scheduler lease fencing; interactive asynchronous transactions are rejected. The cut-over runtime has no recurring YNAB sync. Schedule occurrences can be materialised explicitly through deterministic, transfer-aware Enter Now and bounded owner catch-up writes. Production also runs a separate daily cron at 00:05 `Asia/Singapore`, capped at 25 fair, re-evaluated occurrences with deterministic retry seeds and count-only failure reporting; preview deliberately has no cron. Account reconciliation uses a shared preview/commit snapshot calculation plus an in-batch assertion so only the named account's eligible cleared transactions can move to reconciled.

First-party username/password authentication uses scrypt password hashes and opaque, hashed sessions. Browsers receive a secure `HttpOnly` cookie; iOS stores its session token in Keychain. Users can create revocable personal API tokens from the browser; only token fingerprints are stored, and each request resolves current owner/editor/viewer plan membership. The static API bearer remains a default-plan integration credential and authorizes one-time first-owner setup.
