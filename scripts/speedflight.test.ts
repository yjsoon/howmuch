import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Execute only the real script's preflight. Never copy its archive/upload body
// into a fixture, even on machines with Xcode or production credentials.
const script = readFileSync(new URL("./speedflight.sh", import.meta.url), "utf8");
const boundary = "# Uncomment for XcodeGen projects:";
expect(script.split(boundary)).toHaveLength(2);
const preflight = script.split(boundary)[0];
expect(preflight).not.toMatch(/xcodebuild|curl|rm -rf/);

let root: string;
let origin: string;
let checkout: string;
let env: Record<string, string>;
let initial: string;

function git(cwd: string, ...args: string[]) {
  const result = Bun.spawnSync(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", ...args], {
    cwd, env, stdout: "pipe", stderr: "pipe",
  });
  if (result.exitCode !== 0) throw new Error(result.stderr.toString());
  return result.stdout.toString().trim();
}

function run(extra: Record<string, string> = {}) {
  return Bun.spawnSync(["bash", "scripts/speedflight.sh", "fixture", "fixture"], {
    cwd: checkout, env: { ...env, ...extra }, stdout: "pipe", stderr: "pipe",
  });
}

function accepted(ref?: string) {
  const head = git(checkout, "rev-parse", "HEAD");
  const result = run(ref ? { SPEEDFLIGHT_SOURCE_REF: ref } : {});
  expect(result.stderr.toString()).not.toContain("publication prerequisite");
  expect(result.exitCode).toBe(0);
  expect(result.stdout.toString()).toContain(`PREFLIGHT_OK ${head} `);
  expect(git(checkout, "rev-parse", "HEAD")).toBe(head);
  expect(git(checkout, "status", "--porcelain")).toBe("");
  return result.stdout.toString();
}

function rejected(message: string, extra: Record<string, string> = {}) {
  const head = git(checkout, "rev-parse", "HEAD");
  const status = git(checkout, "status", "--porcelain");
  const result = run(extra);
  expect(result.exitCode).not.toBe(0);
  expect(result.stderr.toString()).toContain(message);
  expect(result.stdout.toString()).not.toContain("PREFLIGHT_OK");
  expect(git(checkout, "rev-parse", "HEAD")).toBe(head);
  expect(git(checkout, "status", "--porcelain")).toBe(status);
}

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "howmuch-speedflight-test-"));
  origin = join(root, "origin");
  checkout = join(root, "checkout");
  mkdirSync(origin);
  env = {
    PATH: process.env.PATH!, HOME: root, GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null",
    GIT_TERMINAL_PROMPT: "0", ASC_KEY_ID: "fixture", ASC_ISSUER_ID: "fixture",
    ASC_PRIVATE_KEY_PATH: join(root, "fixture.p8"), SPEEDFLIGHT_SECRET: "fixture",
    SPEEDFLIGHT_DEEP_LINK: "howmuch://", SPEEDFLIGHT_AUTHOR: "fixture",
  };
  writeFileSync(env.ASC_PRIVATE_KEY_PATH, "fixture only", { mode: 0o600 });
  git(origin, "init", "--initial-branch=main");
  mkdirSync(join(origin, "scripts"));
  writeFileSync(join(origin, "scripts/speedflight.sh"), preflight + '\nprintf "PREFLIGHT_OK %s %s\\n" "$COMMIT" "$BRANCH"\n');
  writeFileSync(join(origin, "tracked"), "initial");
  git(origin, "add", ".");
  git(origin, "commit", "-m", "fixture initial");
  initial = git(origin, "rev-parse", "HEAD");
  git(root, "clone", origin, checkout);
});

afterEach(() => rmSync(root, { recursive: true, force: true }));

test("accepts a clean remote branch without changing HEAD", () => {
  accepted();
});

test("does not require an upstream when the selected origin branch contains HEAD", () => {
  git(checkout, "branch", "--unset-upstream");
  accepted("refs/heads/main");
});

test("accepts an exact detached ancestor without substituting the latest remote commit", () => {
  writeFileSync(join(origin, "tracked"), "new remote version");
  git(origin, "commit", "-am", "remote advance");
  git(checkout, "checkout", "--detach", initial);
  expect(accepted("refs/heads/main")).toContain(`PREFLIGHT_OK ${initial} main`);
});

test("accepts a detached revision reachable only through an annotated remote tag", () => {
  writeFileSync(join(origin, "tracked"), "tagged version");
  git(origin, "commit", "-am", "tag target");
  git(origin, "tag", "-a", "release-fixture", "-m", "fixture tag");
  git(origin, "reset", "--hard", initial);
  git(checkout, "fetch", "origin", "refs/tags/release-fixture");
  git(checkout, "checkout", "--detach", "FETCH_HEAD");
  expect(accepted("refs/tags/release-fixture")).toContain(" release-fixture");
});

test("requires an explicit origin ref for detached HEAD", () => {
  git(checkout, "checkout", "--detach");
  rejected("SPEEDFLIGHT_SOURCE_REF");
});

test("rejects raw hashes, shorthand, and non-branch/tag refs", () => {
  for (const ref of [initial, "main", "refs/remotes/origin/main", "refs/heads/bad..ref"]) {
    rejected("origin branch or tag", { SPEEDFLIGHT_SOURCE_REF: ref });
  }
});

test("rejects an unpushed commit, including with CI set", () => {
  writeFileSync(join(checkout, "tracked"), "local change");
  git(checkout, "commit", "-am", "local only");
  rejected("HEAD is not contained");
  rejected("HEAD is not contained", { CI: "1" });
});

test("rejects dirty tracked and untracked files without modifying them", () => {
  writeFileSync(join(checkout, "tracked"), "dirty");
  rejected("working tree must be clean");
  git(checkout, "restore", "tracked");
  writeFileSync(join(checkout, "untracked"), "keep me");
  rejected("working tree must be clean");
});

test("ignores stale remote-tracking evidence after the origin branch rewinds", () => {
  writeFileSync(join(origin, "tracked"), "later version");
  git(origin, "commit", "-am", "later version");
  git(checkout, "fetch", "origin");
  git(checkout, "checkout", "--detach", "origin/main");
  git(origin, "reset", "--hard", initial);
  rejected("HEAD is not contained", { SPEEDFLIGHT_SOURCE_REF: "refs/heads/main" });
});

test("rejects a deleted remote ref despite an existing local tracking ref", () => {
  git(origin, "branch", "temporary");
  git(checkout, "fetch", "origin");
  git(origin, "branch", "-D", "temporary");
  rejected("could not fetch", { SPEEDFLIGHT_SOURCE_REF: "refs/heads/temporary" });
});

test("rejects unreachable origin instead of trusting cached refs", () => {
  git(checkout, "remote", "set-url", "origin", join(root, "missing"));
  rejected("could not fetch");
});
