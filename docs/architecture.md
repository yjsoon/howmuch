# Architecture

- `apps/api`: shared domain/HTTP code, local SQLite repository, D1 atomic repository and async reports.
- `apps/worker`: D1-only Worker composition, assets, and hourly scheduled sync.
- `apps/web`: React client.

Local development remains Bun/SQLite. Hosted storage is D1 only. D1 mutations are preplanned atomic batches guarded by write versions, immutable command receipts, SQL assertions, and scheduler lease fencing; interactive asynchronous transactions are rejected.

Static bearer authentication remains the active request gate. The schema now includes auth-ready users, external identities, hashed sessions, and many-to-many plan memberships, but no runtime identity/session flow is enabled yet.
