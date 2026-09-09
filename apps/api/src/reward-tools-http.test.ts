import { Database } from "bun:sqlite";
import { expect, test } from "bun:test";
import { applyMigrations } from "./db";
import { createHandler } from "./http";

test("native tools require authentication, same-origin CSRF, and plan permission before parsing", async () => {
  const db = new Database(":memory:"); applyMigrations(db);
  const handler = createHandler({ db, config: { dbPath: ":memory:", port: 0, apiToken: "test-token", defaultPlanId: "test-plan", transitionReadOnly: false } });
  try {
    for (const route of ["reward-terms", "statement-formatter"]) {
      const request = (headers: Record<string, string>, plan = "test-plan") => handler(new Request(`https://howmuch.test/api/tools/${route}?plan_id=${plan}`, { method: "POST", headers, body: "not JSON" }));
      expect((await request({ origin: "https://howmuch.test" })).status).toBe(401);
      expect((await request({ authorization: "Bearer test-token" })).status).toBe(403);
      expect((await request({ authorization: "Bearer test-token", origin: "https://evil.test" })).status).toBe(403);
      expect((await request({ authorization: "Bearer test-token", origin: "https://howmuch.test" }, "other-plan")).status).toBe(404);
      const allowed = await request({ authorization: "Bearer test-token", origin: "https://howmuch.test" });
      expect(allowed.status).toBe(400);
      expect((await allowed.json()).error.detail).toContain("Invalid JSON");
    }
  } finally { db.close(); }
});
