import { DEFAULT_YNAB_SYNC_INTERVAL_MS, loadConfig } from "./config";
import { openDatabase } from "./db";
import { createHandler } from "./http";
import { LedgerRepository } from "./repository";
import { startYnabSync } from "./sync";

const config = loadConfig();
const db = openDatabase(config.dbPath);
const handler = createHandler({ db, config });

Bun.serve({
  port: config.port,
  fetch: handler,
});

console.log(`HowMuch API listening on http://localhost:${config.port}`);

const ynabSync = startYnabSync(new LedgerRepository(db, config.defaultPlanId), config);
if (ynabSync) {
  const intervalMs = config.ynabSyncIntervalMs ?? DEFAULT_YNAB_SYNC_INTERVAL_MS;
  console.log(`YNAB sync enabled, checking every ${Math.round(intervalMs / 60000)} minutes`);
}
