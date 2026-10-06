import { DEFAULT_HOSTNAME, DEFAULT_YNAB_SYNC_INTERVAL_MS, isLoopbackHost, loadConfig } from "./config";
import { openDatabase } from "./db";
import { createHandler } from "./http";
import { LedgerRepository } from "./repository";
import { startYnabSync } from "./sync";

const config = loadConfig();
const hostname = config.hostname ?? DEFAULT_HOSTNAME;

// First-time setup is open to any caller when no static token is configured,
// so only loopback may be served without one.
if (!isLoopbackHost(hostname) && !config.apiToken) {
  console.error(
    `Refusing to listen on ${hostname}: HOWMUCH_API_TOKEN is not set. ` +
      "Set HOWMUCH_API_TOKEN to serve beyond this machine, or unset HOWMUCH_HOST to listen on 127.0.0.1 only.",
  );
  process.exit(1);
}

const db = openDatabase(config.dbPath);
const handler = createHandler({ db, config });

Bun.serve({
  hostname,
  port: config.port,
  fetch: handler,
});

console.log(`HowMuch API listening on http://${hostname.includes(":") ? `[${hostname}]` : hostname}:${config.port}`);

const ynabSync = startYnabSync(new LedgerRepository(db, config.defaultPlanId), config);
if (ynabSync) {
  const intervalMs = config.ynabSyncIntervalMs ?? DEFAULT_YNAB_SYNC_INTERVAL_MS;
  console.log(`YNAB sync enabled, checking every ${Math.round(intervalMs / 60000)} minutes`);
}
