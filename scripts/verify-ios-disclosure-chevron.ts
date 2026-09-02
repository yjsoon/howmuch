import { readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { findFormDisclosureChevronFaults } from "./lib/ios-disclosure-chevron";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const iosRoot = join(root, "apps/ios");

function walk(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    return statSync(path).isDirectory() ? walk(path) : path.endsWith(".swift") ? [path] : [];
  });
}

const faults = findFormDisclosureChevronFaults(
  walk(iosRoot).map((path) => ({
    path: relative(root, path),
    source: readFileSync(path, "utf8"),
  })),
);

if (faults.length) {
  console.error("Form NavigationLinks must not also draw DisclosureValueRow's chevron:");
  for (const fault of faults) {
    console.error(`  ${fault.path}:${fault.line} ${fault.detail}`);
  }
  process.exit(1);
}

console.log("iOS disclosure rows: Form labels hide the custom chevron.");
