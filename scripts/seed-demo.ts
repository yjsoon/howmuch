import { seedDemoLedger } from "./lib/demo-seed";

const dbPath = Bun.env.HOWMUCH_DB_PATH ?? process.argv[2] ?? "data/howmuch.sqlite";
const planId = Bun.env.HOWMUCH_DEFAULT_PLAN_ID;

const result = await seedDemoLedger({ dbPath, planId });

console.log(`Seeded demo ledger into ${result.dbPath}`);
console.log(`Fixture: ${result.fixturePath}`);
console.log(`Plan id: ${result.planId}`);
