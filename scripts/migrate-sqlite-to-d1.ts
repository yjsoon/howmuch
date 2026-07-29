import { Database } from "bun:sqlite";
import { mkdir, rm } from "node:fs/promises";
import { writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { assertInactiveTarget, generateChunks, logicalSourceHash, reconcileCheckpoints, reconcileRun, type Checkpoint, type MigrationRun } from "./lib/d1-ledger-import";

const args = parse(Bun.argv.slice(2));
const source = resolve(args.sqlite); const out = resolve(args.output);
if (args.execute) assertInactiveTarget(args.name, args.id, args.confirm);
await rm(out, { recursive: true, force: true }); await mkdir(out, { recursive: true });
const db = new Database(source, { readonly: true, strict: true });
const generated: Array<{ file: string; checkpoint: Checkpoint }> = [];
const stat = await Bun.file(source).stat();
let sha: string; let runId: string;
try {
  db.exec("BEGIN");
  sha = logicalSourceHash(db); runId = `sqlite-${sha.slice(0, 24)}`;
  let index = 0;
  generateChunks(db, sha, runId, { maxRows: args.rows, maxBytes: args.bytes }, (sql, checkpoint) => {
    const file = resolve(out, `${String(index++).padStart(6, "0")}-${checkpoint.table_name}.sql`);
    writeFileSync(file, sql); generated.push({ file, checkpoint });
  });
} finally { if (db.inTransaction) db.exec("ROLLBACK"); db.close(); }
const manifest = { format: 2, run_id: runId!, source_sha256: sha!, source_bytes: stat.size, chunks: generated.map((x) => x.checkpoint) };
await Bun.write(resolve(out, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
console.error(`Generated ${generated.length} bounded chunks in ${out} (no remote writes yet).`);
if (args.execute) {
  const info = await wrangler(["d1", "info", args.name!, "--json"]);
  if (findString(JSON.parse(info), args.id!) !== args.id) throw new Error("Wrangler database identity does not match --database-id");
  const runsRaw = await wrangler(["d1", "execute", args.name!, "--remote", "--json", "--command", "SELECT id,source_sha256,source_bytes,expected_chunk_count,status FROM migration_runs ORDER BY created_at"]);
  const existingRun = reconcileRun({ id: runId!, source_sha256: sha!, source_bytes: stat.size, expected_chunk_count: manifest.chunks.length }, extractRows<MigrationRun>(JSON.parse(runsRaw)));
  const raw = await wrangler(["d1", "execute", args.name!, "--remote", "--json", "--command", `SELECT source_sha256,table_name,chunk_number,row_count,chunk_sha256,first_stable_key,last_stable_key FROM migration_chunks WHERE run_id='${runId}' ORDER BY table_name,chunk_number`]);
  const existing = extractRows<Checkpoint>(JSON.parse(raw));
  const done = reconcileCheckpoints(manifest.chunks, existing);
  if (existingRun?.status === "complete" && done.size !== manifest.chunks.length) throw new Error("Completed D1 import is missing expected checkpoints");
  if (!existingRun) {
    const command = `INSERT INTO migration_runs(id,source_sha256,source_bytes,expected_chunk_count) VALUES ('${runId}','${sha}',${stat.size},${manifest.chunks.length})`;
    await wrangler(["d1", "execute", args.name!, "--remote", "--yes", "--command", command]);
  }
  for (const item of generated) if (!done.has(`${item.checkpoint.table_name}:${item.checkpoint.chunk_number}`)) await wrangler(["d1", "execute", args.name!, "--remote", "--yes", "--file", item.file]);
  const finish = `UPDATE migration_runs SET status='complete',completed_at=CURRENT_TIMESTAMP WHERE id='${runId}' AND status='running' AND expected_chunk_count=${manifest.chunks.length} AND (SELECT COUNT(*) FROM migration_chunks WHERE run_id='${runId}')=${manifest.chunks.length}`;
  await wrangler(["d1", "execute", args.name!, "--remote", "--yes", "--command", finish]);
  const finalRaw = await wrangler(["d1", "execute", args.name!, "--remote", "--json", "--command", `SELECT status,(SELECT COUNT(*) FROM migration_chunks WHERE run_id='${runId}') chunk_count FROM migration_runs WHERE id='${runId}'`]);
  const final = extractRows<{ status?: string; chunk_count?: number }>(JSON.parse(finalRaw))[0];
  if (final?.status !== "complete" || Number(final.chunk_count) !== manifest.chunks.length) throw new Error("D1 import did not reach a complete, fully checkpointed state");
}
async function wrangler(argv: string[]) { const p = Bun.spawn(["bunx", "wrangler", ...argv], { stdout: "pipe", stderr: "inherit", env: process.env }); const text = await new Response(p.stdout).text(); if (await p.exited) throw new Error("Wrangler command failed"); return text; }
function extractRows<Row>(value: any): Row[] { return (value?.[0]?.results ?? value?.results ?? []) as Row[]; }
function findString(value: unknown, wanted: string): string | undefined { if (value === wanted) return wanted; if (Array.isArray(value)) return value.map((item) => findString(item, wanted)).find(Boolean); if (value && typeof value === "object") return Object.values(value).map((item) => findString(item, wanted)).find(Boolean); }
function parse(argv: string[]) { const o: any = { sqlite: "data/howmuch-real.sqlite", output: "data/d1-import", rows: 200, bytes: 750000, execute: false }; for (let i=0;i<argv.length;i++) { const k=argv[i], v=argv[i+1]; if (["--sqlite","--output","--max-rows","--max-bytes","--database-name","--database-id","--confirm-inactive"].includes(k!)) { if (!v) throw Error(`Missing ${k}`); const names:any={"--sqlite":"sqlite","--output":"output","--max-rows":"rows","--max-bytes":"bytes","--database-name":"name","--database-id":"id","--confirm-inactive":"confirm"}; o[names[k!]]=k!.includes("rows")||k!.includes("bytes")?Number(v):v; i++; } else if(k==="--execute") o.execute=true; else throw Error(`Unknown argument ${k}`); } return o; }
