import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const source = readFileSync(join(root, "apps/ios/HowMuch/Services/APIClient.swift"), "utf8");

const failures: string[] = [];
if (source.includes("?expected_approved=")) {
  failures.push(
    "deleteTransaction must not concatenate expected_approved onto the path; encodedPath percent-encodes `?` as %3F and the API then 404s.",
  );
}
if (!source.includes('URLQueryItem(name: "expected_approved"')) {
  failures.push("deleteTransaction must send expected_approved as a URLQueryItem.");
}

if (failures.length) {
  console.error("iOS transaction delete URL is wrong:");
  for (const failure of failures) console.error(`  ${failure}`);
  process.exit(1);
}

console.log("iOS transaction delete: expected_approved is a query item, not a path suffix.");
