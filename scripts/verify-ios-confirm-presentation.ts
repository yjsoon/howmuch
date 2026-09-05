import { readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const iosRoot = join(root, "apps/ios");
const ALLOWED: string[] = [
  "apps/ios/HowMuch/Views/RegisterView.swift:222", // Retry and discard are two actions
];
const pattern = /\.confirmationDialog\s*\(/g;

function walk(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    return statSync(path).isDirectory() ? walk(path) : path.endsWith(".swift") ? [path] : [];
  });
}

const hits = walk(iosRoot).flatMap((file) => {
  const source = readFileSync(file, "utf8");
  const rel = relative(root, file);
  return [...source.matchAll(pattern)].flatMap((match) => {
    const line = source.slice(0, match.index ?? 0).split("\n").length;
    const loc = `${rel}:${line}`;
    return ALLOWED.includes(loc) ? [] : [loc];
  });
});

if (hits.length > 0) {
  console.error(
    "Binary confirms must use View.binaryConfirm. .confirmationDialog becomes a tap-outside popover on a regular size class. Add a multi-choice dialog to ALLOWED only with a one-line reason.",
  );
  for (const hit of hits) console.error(`  ${hit}`);
  process.exit(1);
}
