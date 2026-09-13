import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const pkg = JSON.parse(readFileSync(new URL("./package.json", import.meta.url), "utf8")) as {
  scripts: Record<string, string>;
};

test("bun run deploy does not invoke wrangler", () => {
  const deploy = pkg.scripts.deploy ?? "";
  expect(deploy).not.toMatch(/wrangler\s+deploy/);
  expect(deploy).toMatch(/exit 1/);
});

test("legacy redirect deploy is named deploy:yj-redirect and pins profile yj", () => {
  expect(pkg.scripts["deploy:yj-redirect"]).toContain("wrangler deploy --profile yj");
  expect(pkg.scripts["deploy:yj-redirect"]).not.toContain("--env tk");
});

test("production deploy stays on env tk and profile tinkertanker", () => {
  expect(pkg.scripts["deploy:tk"]).toContain("wrangler deploy --env tk --profile tinkertanker");
});
