import { loadConfig } from "./config";
import { openDatabase } from "./db";
import { createHandler } from "./http";

const config = loadConfig();
const db = openDatabase(config.dbPath);
const handler = createHandler({ db, config });

Bun.serve({
  port: config.port,
  fetch: handler,
});

console.log(`HowMuch API listening on http://localhost:${config.port}`);

