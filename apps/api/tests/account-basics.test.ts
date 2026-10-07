import { afterEach, describe, expect, test } from "bun:test";
import { sha256 } from "../src/password-auth";
import { API_TOKEN, BACKENDS, sessionFor, nativeHarness, type NativeHarness } from "./helpers/native-harness";

/**
 * Failure modes these isolated tests pin, none of which the browser E2E run
 * would notice (it only watches one happy path in two browser contexts):
 *
 * Password change
 *  - the other sessions survive the change (a stolen cookie keeps working);
 *  - the session making the change is revoked too (user logged out mid-save);
 *  - a static bootstrap token or personal API token is accepted as "the user";
 *  - the endpoint becomes an unthrottled password oracle;
 *  - a cookie request skips the same-origin check that logout performs.
 * Plan settings
 *  - an editor or viewer rewrites the plan's currency;
 *  - an invalid seed is half-applied (one field written, the other rejected);
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

async function open(backend: (typeof BACKENDS)[number]): Promise<NativeHarness> {
  const harness = await nativeHarness(backend);
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
    test("password change revokes other sessions, keeps this one, and leaves personal tokens alone", async () => {
      const harness = await open(backend);
      const { cookie, tokenA, tokenB } = await ownerWithSessions(harness);
      const created = await post(harness, "/api/auth/personal-tokens", { name: "Script" }, { cookie });
      const personal = (await created.json()).data.value as string;

      const changed = await post(harness, "/api/auth/password",
        { current_password: PASSWORD, new_password: NEXT_PASSWORD }, { authorization: `Bearer ${tokenA}` });
      expect(changed.status).toBe(200);

      expect(await status(harness, { authorization: `Bearer ${tokenA}` })).toBe(200);
      expect(await status(harness, { authorization: `Bearer ${tokenB}` })).toBe(401);
      expect(await status(harness, { cookie })).toBe(401);
      expect(await status(harness, { authorization: `Bearer ${personal}` })).toBe(200);

      expect((await post(harness, "/api/auth/token", { username: "owner", password: PASSWORD })).status).toBe(401);
      expect((await post(harness, "/api/auth/token", { username: "owner", password: NEXT_PASSWORD })).status).toBe(200);
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

    test("wrong current passwords are rate limited like login attempts", async () => {
      const harness = await open(backend);
      const { tokenA } = await ownerWithSessions(harness);
      const auth = { authorization: `Bearer ${tokenA}` };
      // Two logins in the helper already spent two attempts of the shared budget.
      const attempt = () => post(harness, "/api/auth/password", { current_password: WRONG_PASSWORD, new_password: NEXT_PASSWORD }, auth);
      let throttled: Response | null = null;
      for (let n = 0; n < 12 && !throttled; n++) {
        const response = await attempt();
        if (response.status === 429) throttled = response;
        else expect(response.status).toBe(401);
      }
      expect(throttled).not.toBeNull();
      expect(throttled!.headers.get("retry-after")).toBe("900");
      // Even the right password is refused while the window is exhausted.
      const right = await post(harness, "/api/auth/password", { current_password: PASSWORD, new_password: NEXT_PASSWORD }, auth);
      expect(right.status).toBe(429);
      expect((await post(harness, "/api/auth/token", { username: "owner", password: NEXT_PASSWORD })).status).toBe(429);
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
