import { afterEach, describe, expect, test } from "bun:test";
import type { AuthStore } from "../src/auth-store";
import { sha256 } from "../src/password-auth";
import { API_TOKEN, BACKENDS, sessionFor, nativeHarness, type NativeHarness } from "./helpers/native-harness";

/**
 * Failure modes these isolated tests pin, none of which the browser E2E run
 * would notice (it only watches one happy path in two browser contexts):
 *
 * Password change
 *  - the other sessions survive the change (a stolen cookie keeps working);
 *  - the session making the change is not replaced, so a token that leaked
 *    before the change is still valid afterwards (it must rotate);
 *  - the session making the change is revoked without a replacement (user
 *    logged out mid-save);
 *  - a login that verified the old password but commits after the change
 *    keeps a fresh 30-day session (session creation must be conditional on
 *    the credential that was verified);
 *  - a JSON `null` or array body reaches property access and returns 500;
 *  - an enormous `current_password` is fed to scrypt before any length check;
 *  - a static bootstrap token or personal API token is accepted as "the user";
 *  - the endpoint becomes an unthrottled password oracle;
 *  - anonymous failed logins for the username exhaust the shared counter and
 *    stop the owner changing their own password (the route needs its own key);
 *  - a cookie request skips the same-origin check that logout performs.
 * Plan settings
 *  - a `null` body returns 500 instead of 400;
 *  - an editor or viewer rewrites the plan's currency;
 *  - an invalid seed is half-applied (one field written, the other rejected);
 *  - re-importing a plan with no `settings` block resets chosen formats to
 *    SGD / DD/MM/YYYY (the D1 upsert used to; SQLite preserves them);
 *  - the change is written but `server_knowledge` does not move, so clients
 *    that validate caches against it keep the old format.
 * Pruning
 *  - a live session, or a rate-limit window still in effect, is deleted,
 *    which would sign people out or reset a brute-force counter.
 *
 * Every case runs on both the SQLite and the D1 store.
 */

const harnesses: NativeHarness[] = [];
afterEach(() => { for (const harness of harnesses.splice(0)) harness.close(); });

const ORIGIN = "https://howmuch.test";
const PASSWORD = ["ledger", "test", "passphrase", "2026"].join("-");
const NEXT_PASSWORD = ["another", "test", "passphrase", "2027"].join("-");
const WRONG_PASSWORD = ["incorrect", "test", "passphrase", "2026"].join("-");

const GBP = {
  iso_code: "GBP", example_format: "£123,456.78", decimal_digits: 2, decimal_separator: ".",
  symbol_first: true, group_separator: ",", currency_symbol: "£", display_symbol: true,
};

async function open(backend: (typeof BACKENDS)[number], wrapAuth?: (store: AuthStore) => AuthStore): Promise<NativeHarness> {
  const harness = await nativeHarness(backend, wrapAuth);
  harnesses.push(harness);
  return harness;
}

function post(harness: NativeHarness, path: string, body: unknown, headers: Record<string, string> = {}): Promise<Response> {
  return harness.handle(new Request(`${ORIGIN}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", origin: ORIGIN, ...headers },
    body: JSON.stringify(body),
  }));
}

/** Owner set up through the real route; returns the setup cookie plus two bearer sessions. */
async function ownerWithSessions(harness: NativeHarness) {
  const setup = await post(harness, "/api/auth/setup", { username: "owner", password: PASSWORD }, { authorization: `Bearer ${API_TOKEN}` });
  expect(setup.status).toBe(200);
  const cookie = setup.headers.get("set-cookie")!.split(";", 1)[0];
  const bearer = async () => (await (await post(harness, "/api/auth/token", { username: "owner", password: PASSWORD })).json()).data.token as string;
  return { cookie, tokenA: await bearer(), tokenB: await bearer() };
}

function status(harness: NativeHarness, headers: Record<string, string>): Promise<number> {
  return harness.handle(new Request(`${ORIGIN}/v1/user`, { headers })).then((response) => response.status);
}

for (const backend of BACKENDS) {
  describe(`account basics (${backend})`, () => {
    test("password change revokes every session, issues a fresh one to the caller, and leaves personal tokens alone", async () => {
      const harness = await open(backend);
      const { cookie, tokenA, tokenB } = await ownerWithSessions(harness);
      const created = await post(harness, "/api/auth/personal-tokens", { name: "Script" }, { cookie });
      const personal = (await created.json()).data.value as string;

      const changed = await post(harness, "/api/auth/password",
        { current_password: PASSWORD, new_password: NEXT_PASSWORD }, { authorization: `Bearer ${tokenA}` });
      expect(changed.status).toBe(200);

      // The calling session is rotated: its old token dies, a fresh one is returned.
      const rotated = (await changed.json()).data as { ok: boolean; token: string; expires_at: number };
      expect(rotated.ok).toBe(true);
      expect(rotated.token).not.toBe(tokenA);
      expect(rotated.expires_at).toBeGreaterThan(Math.floor(Date.now() / 1000));
      expect(changed.headers.get("set-cookie")).toBeNull();
      expect(await status(harness, { authorization: `Bearer ${tokenA}` })).toBe(401);
      expect(await status(harness, { authorization: `Bearer ${rotated.token}` })).toBe(200);
      expect(await status(harness, { authorization: `Bearer ${tokenB}` })).toBe(401);
      expect(await status(harness, { cookie })).toBe(401);
      expect(await status(harness, { authorization: `Bearer ${personal}` })).toBe(200);

      expect((await post(harness, "/api/auth/token", { username: "owner", password: PASSWORD })).status).toBe(401);
      expect((await post(harness, "/api/auth/token", { username: "owner", password: NEXT_PASSWORD })).status).toBe(200);
    });

    test("a cookie session is rotated through a new cookie, and the old cookie stops working", async () => {
      const harness = await open(backend);
      const { cookie, tokenA } = await ownerWithSessions(harness);
      const changed = await post(harness, "/api/auth/password", { current_password: PASSWORD, new_password: NEXT_PASSWORD }, { cookie });
      expect(changed.status).toBe(200);
      const setCookie = changed.headers.get("set-cookie")!;
      expect(setCookie).toMatch(/^__Host-howmuch_session=[^;]+; HttpOnly; Secure; SameSite=Lax; Path=\/; Max-Age=\d+$/);
      const fresh = setCookie.split(";", 1)[0];
      expect(fresh).not.toBe(cookie);
      expect((await changed.json()).data.token).toBeUndefined();
      expect(await status(harness, { cookie })).toBe(401);
      expect(await status(harness, { cookie: fresh })).toBe(200);
      expect(await status(harness, { authorization: `Bearer ${tokenA}` })).toBe(401);
    });

    test("a login that verified the old password cannot start a session after the password changed", async () => {
      let armed = false;
      let db!: NativeHarness["db"];
      // Commits a password change between the login's password check and its
      // session insert, with no timing involved: the hook runs inside createSession.
      const harness = await open(backend, (store) => new Proxy(store, {
        get(target, property, receiver) {
          const value = Reflect.get(target, property, receiver);
          if (typeof value !== "function") return value;
          if (property !== "createSession") return value.bind(target);
          return async (...args: unknown[]) => {
            if (armed) {
              armed = false;
              db.run("UPDATE password_credentials SET hash_hex=?, salt_hex=?", ["0".repeat(64), "1".repeat(32)]);
              db.run("UPDATE sessions SET revoked_at=unixepoch() WHERE revoked_at IS NULL");
            }
            return value.apply(target, args);
          };
        },
      }));
      db = harness.db;
      const setup = await post(harness, "/api/auth/setup", { username: "owner", password: PASSWORD }, { authorization: `Bearer ${API_TOKEN}` });
      expect(setup.status).toBe(200);

      armed = true;
      const attacker = await post(harness, "/api/auth/token", { username: "owner", password: PASSWORD });
      expect(attacker.status).toBe(401);
      expect(db.query("SELECT COUNT(*) AS n FROM sessions WHERE revoked_at IS NULL").get()).toEqual({ n: 0 });
    });

    test("only a signed-in user session may change the password", async () => {
      const harness = await open(backend);
      const { cookie, tokenA } = await ownerWithSessions(harness);
      const personal = (await (await post(harness, "/api/auth/personal-tokens", { name: "Script" }, { cookie })).json()).data.value as string;
      const body = { current_password: PASSWORD, new_password: NEXT_PASSWORD };

      expect((await post(harness, "/api/auth/password", body, { authorization: `Bearer ${API_TOKEN}` })).status).toBe(401);
      expect((await post(harness, "/api/auth/password", body, { authorization: `Bearer ${personal}` })).status).toBe(401);
      expect((await post(harness, "/api/auth/password", body)).status).toBe(401);
      // A cookie request with no Origin must fail the CSRF check, as logout does.
      const noOrigin = await harness.handle(new Request(`${ORIGIN}/api/auth/password`, {
        method: "POST", headers: { "content-type": "application/json", cookie }, body: JSON.stringify(body),
      }));
      expect(noOrigin.status).toBe(403);
      // None of the refusals changed the credential or revoked anything.
      expect(await status(harness, { authorization: `Bearer ${tokenA}` })).toBe(200);
      expect((await post(harness, "/api/auth/token", { username: "owner", password: PASSWORD })).status).toBe(200);
    });

    test("rejects bad new passwords and a wrong current password without changing anything", async () => {
      const harness = await open(backend);
      const { tokenA, tokenB } = await ownerWithSessions(harness);
      const auth = { authorization: `Bearer ${tokenA}` };

      expect((await post(harness, "/api/auth/password", { current_password: PASSWORD, new_password: "short" }, auth)).status).toBe(400);
      expect((await post(harness, "/api/auth/password", { current_password: PASSWORD, new_password: PASSWORD }, auth)).status).toBe(400);
      expect((await post(harness, "/api/auth/password", { new_password: NEXT_PASSWORD }, auth)).status).toBe(400);
      const wrong = await post(harness, "/api/auth/password", { current_password: WRONG_PASSWORD, new_password: NEXT_PASSWORD }, auth);
      expect(wrong.status).toBe(401);
      expect((await wrong.json()).error.detail).toBe("Current password is incorrect");
      expect(await status(harness, { authorization: `Bearer ${tokenB}` })).toBe(200);
    });

    test("wrong current passwords are rate limited on their own budget, apart from logins", async () => {
      const harness = await open(backend);
      const { tokenA } = await ownerWithSessions(harness);
      const auth = { authorization: `Bearer ${tokenA}` };
      const attempt = () => post(harness, "/api/auth/password", { current_password: WRONG_PASSWORD, new_password: NEXT_PASSWORD }, auth);
      // The route allows ten guesses per window: ten 401s, then 429.
      for (let n = 0; n < 10; n++) expect((await attempt()).status).toBe(401);
      const throttled = await attempt();
      expect(throttled.status).toBe(429);
      expect(throttled.headers.get("retry-after")).toBe("900");
      // Even the right password is refused while the window is exhausted.
      const right = await post(harness, "/api/auth/password", { current_password: PASSWORD, new_password: NEXT_PASSWORD }, auth);
      expect(right.status).toBe(429);
      // Signing in is a separate budget and is not starved by the route's guesses.
      expect((await post(harness, "/api/auth/token", { username: "owner", password: PASSWORD })).status).toBe(200);
    });

    test("anonymous failed logins for the username do not block the owner changing their password", async () => {
      const harness = await open(backend);
      const { cookie } = await ownerWithSessions(harness);
      const codes: number[] = [];
      for (let n = 0; n < 12; n++) {
        codes.push((await post(harness, "/api/auth/token", { username: "owner", password: WRONG_PASSWORD }, { "cf-connecting-ip": `10.0.0.${n}` })).status);
      }
      expect(codes.at(-1)).toBe(429);
      const changed = await post(harness, "/api/auth/password", { current_password: PASSWORD, new_password: NEXT_PASSWORD }, { cookie });
      expect(changed.status).toBe(200);
    });

    test("non-object JSON bodies and oversized current passwords are 400s, not 500s or scrypt work", async () => {
      const harness = await open(backend);
      const { tokenA } = await ownerWithSessions(harness);
      const auth = { authorization: `Bearer ${tokenA}` };
      for (const raw of ["null", "[]", "42", '"text"']) {
        const request = (path: string, method: string, headers: Record<string, string>) =>
          harness.handle(new Request(`${ORIGIN}${path}`, { method, headers: { "content-type": "application/json", origin: ORIGIN, ...headers }, body: raw }));
        expect((await request("/api/auth/password", "POST", auth)).status).toBe(400);
        expect((await request("/api/plans/p/settings", "PATCH", { authorization: `Bearer ${API_TOKEN}` })).status).toBe(400);
      }
      // 300 bytes is over the limit login applies; it is refused before any hashing or rate-limit spend.
      const huge = await post(harness, "/api/auth/password", { current_password: "x".repeat(300), new_password: NEXT_PASSWORD }, auth);
      expect(huge.status).toBe(400);
      const user = harness.db.query("SELECT id FROM users LIMIT 1").get() as { id: string };
      expect(harness.db.query("SELECT COUNT(*) AS n FROM login_rate_limits WHERE key_hash=?").get(sha256(`pwchange:${user.id}`))).toEqual({ n: 0 });
    });

    test("only owners change plan formats, invalid seeds write nothing, and knowledge moves", async () => {
      const harness = await open(backend);
      const owner = sessionFor(harness.db, "owner");
      const editor = sessionFor(harness.db, "editor");
      const viewer = sessionFor(harness.db, "viewer");
      const read = async () => (await (await harness.request("/v1/plans/p/settings")).json()).data.settings;
      const knowledge = async () => (await (await harness.request("/v1/plans/p")).json()).data.plan.server_knowledge as number;
      const patch = (token: string, body: unknown) => harness.request("/api/plans/p/settings", { method: "PATCH", token, body });

      const before = await read();
      const knowledgeBefore = await knowledge();

      expect((await patch(editor, { currency_format: GBP })).status).toBe(403);
      expect((await patch(viewer, { currency_format: GBP })).status).toBe(403);
      expect((await patch(owner, {})).status).toBe(400);
      // Valid date but invalid currency: the valid half must not be applied.
      expect((await patch(owner, { date_format: { format: "YYYY-MM-DD" }, currency_format: { ...GBP, decimal_separator: "," } })).status).toBe(400);
      expect((await patch(owner, { date_format: { format: "D/M/Y" } })).status).toBe(400);
      expect(await read()).toEqual(before);
      expect(await knowledge()).toBe(knowledgeBefore);

      const ok = await patch(owner, { currency_format: GBP, date_format: { format: "YYYY-MM-DD" } });
      expect(ok.status).toBe(200);
      const after = await read();
      expect(after.currency_format).toEqual(GBP);
      expect(after.date_format).toEqual({ format: "YYYY-MM-DD" });
      expect(after.display).toEqual(before.display);
      expect(await knowledge()).toBeGreaterThan(knowledgeBefore);

      // One field alone leaves the other untouched.
      expect((await patch(owner, { date_format: { format: "MM/DD/YYYY" } })).status).toBe(200);
      const partial = await read();
      expect(partial.currency_format).toEqual(GBP);
      expect(partial.date_format).toEqual({ format: "MM/DD/YYYY" });

      // The static token is confined to the default plan, like other plan routes.
      expect((await harness.request("/api/plans/p/settings", { method: "PATCH", body: { date_format: { format: "DD/MM/YYYY" } } })).status).toBe(200);
      expect((await harness.request("/api/plans/nope/settings", { method: "PATCH", body: { date_format: { format: "DD/MM/YYYY" } } })).status).toBe(404);
    });

    test("upserting a plan without settings keeps the formats an owner chose", async () => {
      const harness = await open(backend);
      const owner = sessionFor(harness.db, "owner");
      const read = async () => (await (await harness.request("/v1/plans/p/settings")).json()).data.settings;
      expect((await harness.request("/api/plans/p/settings", { method: "PATCH", token: owner, body: { currency_format: GBP, date_format: { format: "YYYY-MM-DD" } } })).status).toBe(200);
      await harness.repo.upsertPlan("p", { name: "Renamed" });
      const after = await read();
      expect(after.currency_format).toEqual(GBP);
      expect(after.date_format).toEqual({ format: "YYYY-MM-DD" });
    });

    test("pruning removes expired sessions and stale rate-limit rows but never live ones", async () => {
      const harness = await open(backend);
      const { tokenA } = await ownerWithSessions(harness);
      const now = Math.floor(Date.now() / 1000);
      const user = harness.db.query("SELECT id FROM users LIMIT 1").get() as { id: string };
      const hash = (label: string) => sha256(label);
      const addSession = (label: string, expiresAt: number, revokedAt: number | null) => harness.db.run(
        "INSERT INTO sessions(id,user_id,token_hash,expires_at,revoked_at) VALUES(?,?,?,?,?)",
        [label, user.id, hash(label), expiresAt, revokedAt],
      );
      addSession("expired-long-ago", now - 90 * 86_400, null);
      addSession("expired-just-now", now - 1, null);
      addSession("live", now + 3_600, null);
      addSession("live-but-revoked", now + 3_600, now - 10);
      const addWindow = (label: string, windowStart: number) => harness.db.run(
        "INSERT INTO login_rate_limits(scope,key_hash,window_start,attempts) VALUES('username',?,?,77)",
        [hash(label), windowStart],
      );
      const currentWindow = Math.floor(now / 900) * 900;
      addWindow("ancient", currentWindow - 3 * 86_400);
      addWindow("ended-two-days-ago", currentWindow - 2 * 86_400);
      addWindow("ended-an-hour-ago", currentWindow - 3_600);
      addWindow("current-window", currentWindow);

      // A successful login is the trigger.
      expect((await post(harness, "/api/auth/token", { username: "owner", password: PASSWORD })).status).toBe(200);

      const sessions = (harness.db.query("SELECT id FROM sessions").all() as Array<{ id: string }>).map((row) => row.id);
      expect(sessions).toContain("live");
      expect(sessions).toContain("live-but-revoked");
      expect(sessions).not.toContain("expired-long-ago");
      expect(sessions).not.toContain("expired-just-now");
      expect(await status(harness, { authorization: `Bearer ${tokenA}` })).toBe(200);

      const windows = (harness.db.query("SELECT window_start FROM login_rate_limits WHERE attempts=77 ORDER BY window_start").all() as Array<{ window_start: number }>).map((row) => row.window_start);
      expect(windows).toEqual([currentWindow - 3_600, currentWindow]);
    });
  });
}
