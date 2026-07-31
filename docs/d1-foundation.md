# D1 Foundation

D1 databases apply `apps/api/d1-migrations/0001_initial.sql` followed by `0002_password_auth.sql`. The first defines the ledger, import, scheduler/receipt, audit, guarded-write, and auth foundation; the second activates first-party password credentials, one-time setup, and login throttling. There is no legacy-data backfill or database-copy tooling.

The account/transfer-payee relationship deliberately uses ordered creation plus ownership triggers rather than immediate cyclic foreign keys. Ledger sequence triggers and unique indexes preserve deterministic ordering. D1 writes remain complete atomic batches with write-version, receipt, assertion, and lease checks.

Wrangler binds the reviewed `howmuch-production` and `howmuch-preview` D1 databases. Both are clean-slate databases; no legacy ledger is copied into them.
