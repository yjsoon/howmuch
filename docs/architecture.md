# Architecture

- `apps/api`: shared domain/HTTP code, local SQLite repository, D1 atomic repository and async reports.
- `apps/worker`: D1-only Worker composition, assets, and hourly scheduled sync.
- `apps/web`: React client.

Local development remains Bun/SQLite. Hosted storage is D1 only. D1 mutations are preplanned atomic batches guarded by write versions, immutable command receipts, SQL assertions, and scheduler lease fencing; interactive asynchronous transactions are rejected.

First-party username/password authentication uses scrypt password hashes and opaque, hashed sessions. Browsers receive a secure `HttpOnly` cookie; iOS stores its session token in Keychain. Session requests are scoped by owner/editor/viewer plan membership. The static API bearer remains a default-plan integration credential and authorizes one-time first-owner setup.
