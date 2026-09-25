// Builds the on-device engine for the iOS app's local mode.
//
//   bun run build:ios-engine   writes the bundle and the migrations into the app
//   bun run check:ios-engine   rebuilds into a temporary directory and fails if
//                              the committed copies are stale
//
// Xcode cannot run bun, so the outputs are committed:
//   apps/ios/HowMuch/Engine/howmuch-engine.js   minified apps/api + shims
//   apps/ios/HowMuch/Engine/migrations/*.sql    copies of apps/api/d1-migrations
import { mkdtempSync, readdirSync, readFileSync, existsSync, mkdirSync, writeFileSync, copyFileSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const root = resolve(import.meta.dir, "..");
const engineSource = join(root, "apps/ios/engine");
const migrationsSource = join(root, "apps/api/d1-migrations");
const outputRoot = join(root, "apps/ios/HowMuch/Engine");
const bundleName = "howmuch-engine.js";

const HEADER = [
  "// GENERATED FILE. DO NOT EDIT.",
  "// Built from apps/ios/engine/entry.ts and apps/api/src by `bun run build:ios-engine`.",
  "// `bun run check:ios-engine` fails when this file is stale.",
  "",
].join("\n");

const shims: import("bun").BunPlugin = {
  name: "howmuch-jsc-shims",
  setup(build) {
    build.onResolve({ filter: /^(node:)?crypto$/ }, () => ({ path: join(engineSource, "shims/node-crypto.js") }));
    build.onResolve({ filter: /^bun:sqlite$/ }, () => ({ path: join(engineSource, "shims/bun-sqlite.js") }));
    build.onResolve({ filter: /^@howmuch\/register-query$/ }, () => ({ path: join(root, "packages/register-query/src/index.ts") }));
  },
};

async function buildBundle(): Promise<string> {
  const result = await Bun.build({
    entrypoints: [join(engineSource, "entry.ts")],
    target: "browser",
    format: "esm",
    minify: true,
    sourcemap: "none",
    plugins: [shims],
  });
  if (!result.success) {
    for (const log of result.logs) console.error(log);
    throw new Error("Engine build failed");
  }
  const text = await result.outputs[0].text();
  // A plain script, not a module: JSContext.evaluateScript cannot load modules.
  if (/^\s*(import|export)\s/m.test(text)) throw new Error("The engine bundle still contains import or export statements");
  // Absolute paths would make the bundle differ between checkouts.
  if (text.includes(root) || /\/Users\/|\/home\//.test(text)) throw new Error("The engine bundle contains an absolute path");
  return HEADER + text;
}

function migrationFiles(): string[] {
  return readdirSync(migrationsSource).filter((name) => name.endsWith(".sql")).sort();
}

async function writeOutputs(target: string): Promise<void> {
  mkdirSync(join(target, "migrations"), { recursive: true });
  writeFileSync(join(target, bundleName), await buildBundle());
  const wanted = new Set(migrationFiles());
  for (const name of readdirSync(join(target, "migrations"))) {
    if (name.endsWith(".sql") && !wanted.has(name)) unlinkSync(join(target, "migrations", name));
  }
  for (const name of wanted) copyFileSync(join(migrationsSource, name), join(target, "migrations", name));
}

function listOutputs(target: string): string[] {
  const migrations = existsSync(join(target, "migrations"))
    ? readdirSync(join(target, "migrations")).filter((name) => name.endsWith(".sql")).map((name) => `migrations/${name}`)
    : [];
  return [bundleName, ...migrations].sort();
}

function staleOutputs(expected: string, actual: string): string[] {
  const stale: string[] = [];
  const expectedFiles = listOutputs(expected);
  const actualFiles = new Set(listOutputs(actual));
  for (const file of expectedFiles) {
    if (!actualFiles.has(file) || !existsSync(join(actual, file))) {
      stale.push(`${file} (missing)`);
    } else if (!readFileSync(join(expected, file)).equals(readFileSync(join(actual, file)))) {
      stale.push(`${file} (differs)`);
    }
    actualFiles.delete(file);
  }
  for (const file of actualFiles) stale.push(`${file} (no longer generated)`);
  return stale;
}

const mode = process.argv[2] ?? "build";
if (mode === "build") {
  await writeOutputs(outputRoot);
  // Build twice and compare, so a nondeterministic build fails here rather
  // than as a spurious check failure on another machine.
  const again = mkdtempSync(join(tmpdir(), "howmuch-ios-engine-"));
  await writeOutputs(again);
  const drift = staleOutputs(again, outputRoot);
  if (drift.length > 0) throw new Error(`The engine build is not deterministic: ${drift.join(", ")}`);
  const size = readFileSync(join(outputRoot, bundleName)).length;
  console.log(`Wrote ${bundleName} (${size} bytes) and ${migrationFiles().length} migrations to apps/ios/HowMuch/Engine`);
} else if (mode === "check") {
  const fresh = mkdtempSync(join(tmpdir(), "howmuch-ios-engine-"));
  await writeOutputs(fresh);
  const stale = staleOutputs(fresh, outputRoot);
  if (stale.length > 0) {
    console.error(`The iOS engine is stale. Run \`bun run build:ios-engine\` and commit the result.\n  ${stale.join("\n  ")}`);
    process.exit(1);
  }
  console.log("The iOS engine is up to date.");
} else {
  console.error("Usage: bun scripts/build-ios-engine.ts [build|check]");
  process.exit(2);
}
