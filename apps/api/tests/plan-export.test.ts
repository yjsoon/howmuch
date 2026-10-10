import { afterEach, describe, expect, test } from "bun:test";
import { BACKENDS, nativeHarness, type NativeHarness } from "./helpers/native-harness";

// The archive promises no credentials, but Rewards cards and the stored
// tracker snapshot keep whatever extra keys an older Rewards Tracker import
// carried. The browser E2E seeds only clean cards, so it misses:
// - a credential key on a card (`apiKey`), copied into `rewards.cards`;
// - the same key in the stored snapshot's copy of the cards;
// - a credential nested deeper (rule settings, connection blocks), and the
//   import-time strip missing a spelling such as `howmuchToken` or `pat`.

const harnesses: NativeHarness[] = [];
afterEach(() => { for (const harness of harnesses.splice(0)) harness.close(); });

const MARKER = "synthetic-secret-marker";

describe.each(BACKENDS)("export everything on %s", (backend) => {
  test("strips credentials carried by imported Rewards data from both copies", async () => {
    const harness = await nativeHarness(backend);
    harnesses.push(harness);
    const payload = {
      cards: [{
        id: "card-1", name: "Rewards Card", issuer: "UOB", type: "cashback", ynabAccountId: "acct-rewards", earningRate: 1,
        apiKey: MARKER,
        extras: { nested: { password: MARKER, accessToken: MARKER, privateKey: MARKER, private_key: MARKER, keep: "visible" } },
      }],
      rules: [{ id: "rule-1", cardId: "card-1", name: "Dining", formatter: { api_key: MARKER, model: "kept" } }],
      tagMappings: [],
      settings: { currency: "SGD", howmuchToken: MARKER, cloudSyncPhrase: MARKER },
      pat: MARKER,
    };
    const imported = await harness.request("/api/import/rewards-tracker?plan_id=p", { method: "POST", body: { payload } });
    expect(imported.status).toBe(201);

    const response = await harness.request("/v1/plans/p/export");
    expect(response.status).toBe(200);
    const text = await response.text();
    expect(text).not.toContain(MARKER);
    const archive = JSON.parse(text);
    expect(archive.rewards.cards).toHaveLength(1);
    expect(archive.rewards.cards[0]).toMatchObject({ id: "card-1", name: "Rewards Card", extras: { nested: { keep: "visible" } } });
  });
});
