# D1 Foundation

Fresh D1 databases apply only `apps/api/d1-migrations/0001_initial.sql`. It directly defines the final ledger, import, scheduler/receipt, audit, guarded-write, and auth-ready schema. There is no historical D1 chain, backfill DML, schema migration tracking, or database-copy tooling.

The account/transfer-payee relationship deliberately uses ordered creation plus ownership triggers rather than immediate cyclic foreign keys. Ledger sequence triggers and unique indexes preserve deterministic ordering. D1 writes remain complete atomic batches with write-version, receipt, assertion, and lease checks.

Wrangler currently has local-only ID-less bindings. No remote D1 is available and deployment is blocked until reviewed IDs are checked in.
