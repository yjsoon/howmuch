# Offline-first writes in server mode

Status: planned 2026-09-25. Companion to [standalone-ios.md](standalone-ios.md). In local mode every write goes straight to the on-device engine, so none of this applies there.

## Premise corrections

- Transaction routes ignore `Idempotency-Key`. Retries are safe for other reasons, so no API change is needed:
  - creates dedupe by `import_id` + `account_id` (`apps/api/src/http.ts` ~452) and accept a client `id`;
  - cleared and delete are compare-and-set (`expected_cleared`, `expected_approved`);
  - PUT is idempotent.
- The capture sheet does not spin when a snapshot exists. The real problems:
  - on an offline warm launch the reference phase turns `.failed`, so capture refuses to open;
  - every delete wipes the snapshot, so the next launch starts cold.

## P0: small, low risk

1. Capture opens whenever accounts are loaded, even if the last refresh failed (`CaptureAdmissionGate.canAdmit`).
2. Deleting a transaction persists the repaired snapshot instead of deleting it.
3. Account create and edit schedule the refresh instead of awaiting it. Account ids stay server-minted, because a client id switches the server to reseed semantics.
4. Reports are stale-while-revalidate:
   - Reflect reports persist next to the snapshot and render instantly;
   - they refresh quietly in the background;
   - Rewards moves into `AppModel` and gets the same cache.

## P1: one durable command outbox

This replaces both the `pendingTransactions` queue and the `pendingEdits` overlay.

- **Storage:** `OutboxCommand`, with fields `id`, `seq`, `transactionID`, `connectionFingerprint`, `kind` (create / update / cleared / approve / delete), `state` (queued / inFlight / rejected) and `baseSnapshot`. It lives in `Application Support/HowMuch/Outbox/outbox.json`. On first load it migrates the UserDefaults `HowMuch.Outbox` payload.
- **Client ids:** the client mints transaction ids (`TransactionWriteRequest.id`). A queued create therefore has a real id at once, and later changes to it coalesce by id.
- **Coalescing:** a pure function, `OutboxPlanner.enqueue`, keeps at most one command per id and never rewrites an in-flight command.
  - create + delete cancels locally;
  - repeated updates keep the first base;
  - toggling cleared back to its original value cancels.
- **Replay:** a pure function, `OutboxPlanner.plan`, sends in this order: creates, updates, cleared (bulk), approve (batch), delete (bulk).
- **Outcomes:**
  - 404 on a delete counts as done;
  - a 409 on cleared triggers a re-GET and compare;
  - a 400 marks the command rejected and keeps it on disk;
  - offline and 5xx errors wait for the next pass.
- **Rejected commands:** they appear in the outbox card with Retry and Discard. Discard reverts from `baseSnapshot`.
- **Balances:** `OutboxPlanner.balanceDeltas` adjusts displayed balances by the effect of queued commands, transfers included. A delta stays applied until the accounts refresh after the ack lands.
- **Delete and the cleared toggle** no longer take the global `isSubmitting` lock.

## Must stay blocking

- **Reconcile:** the server asserts the statement balance. Drain the queue first, and disable Reconcile while that account has queued commands.
- **Schedule materialize:** the server computes the occurrence.
- **Schedule save and delete:** these could be queued later, because they already send `Idempotency-Key`.
- **Account create:** needs a server-minted id.

## Tests

`OutboxPlannerTests` should cover:

- every coalescing rule, plus a property test that keeps at most one command per id;
- replay ordering;
- mapping each outcome to its action;
- balance deltas for transfers, account moves and cleared toggles;
- migration from UserDefaults, and quarantining a corrupt file.

Also add capture admission and snapshot-overlay tests.
