import { expect, test } from "bun:test";
import { portableRewardsExport } from "./rewards-export";

test("exports current cards and portable rules without cached data or credentials", () => {
  const result = portableRewardsExport({ cards: [{ id: "current", maximumSpend: null, earningRate: 0 } as never],
    snapshot: { cards: [{ id: "stale" } as never], rules: [{ id: "rule", apiKey: "secret" }], tagMappings: [{ id: "tag" }],
      settings: { milesValuation: 0, cloudSyncMnemonic: "secret", statementFormatter: { apiKeys: { openai: "secret" } },
        apiKeys: { anthropic: "secret" }, categoryImport: { credentials: "secret", providerKey: "secret" }, currency: "SGD" } },
    imported_at: null, updated_at: null });
  expect(result.cards).toEqual([{ id: "current", maximumSpend: null, earningRate: 0 }]);
  expect(result.rules).toEqual([{ id: "rule" }]);
  expect(result.settings).toEqual({ milesValuation: 0, currency: "SGD", statementFormatter: {} });
  expect(JSON.stringify(result)).not.toContain("secret");
  expect(result).not.toHaveProperty("cachedData");
});

test("retains portable dashboard and theme configuration without embedded authorization", () => {
  const result = portableRewardsExport({ cards: [], imported_at: null, updated_at: null,
    snapshot: { themeGroups: [{ id: "dining", cards: [{ cardId: "card" }] }], hiddenCards: [{ cardId: "old", hiddenUntil: "2026-12-01" }],
      settings: { cardOrdering: { miles: ["card"] }, collapsedCardGroups: { miles: true },
        statementFormatter: { provider: "openai", apiKeys: { openai: "secret" }, authorization: "secret" } } } });
  expect(result.themeGroups).toEqual([{ id: "dining", cards: [{ cardId: "card" }] }]);
  expect(result.hiddenCards).toEqual([{ cardId: "old", hiddenUntil: "2026-12-01" }]);
  expect(result.settings).toMatchObject({ cardOrdering: { miles: ["card"] }, collapsedCardGroups: { miles: true }, statementFormatter: { provider: "openai" } });
  expect(JSON.stringify(result)).not.toContain("secret");
});
