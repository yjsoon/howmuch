import { generateYnabD1Bootstrap } from "./lib/ynab-d1-bootstrap";

const args = Bun.argv.slice(2);
if (args.includes("--help") || args.includes("-h")) {
  console.log(`Generate a validated, data-only Cloudflare D1 bootstrap SQL file.\n\nUsage:\n  bun run bootstrap:ynab-d1 --db <fresh-local.sqlite> [--out data/ynab-d1-bootstrap.sql]\n\nThe output must not already exist. No network or remote operation is performed.`);
  process.exit(0);
}
function value(name: string, fallback?: string) { const i = args.indexOf(name); if (i < 0) return fallback; if (!args[i + 1]) throw new Error(`${name} requires a value`); return args[i + 1]; }
const db = value("--db");
if (!db) throw new Error("--db is required (use --help for usage)");
const out = value("--out", "data/ynab-d1-bootstrap.sql")!;
const manifest = generateYnabD1Bootstrap(db, out);
console.log(`Validated ${manifest.counts.transactions.active + manifest.counts.transactions.deleted} transactions; wrote ${out} (${manifest.sql_bytes} bytes)`);
console.log(`Manifest: ${out}.manifest.json`);
