import { loadConfig } from "./config";
import { openDatabase } from "./db";

const config = loadConfig();
const db = openDatabase(config.dbPath);
db.close();

console.log(`Migrated ${config.dbPath}`);

