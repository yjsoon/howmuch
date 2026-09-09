import type { RewardsTrackerSnapshot } from "../api/client";

export function portableRewardsExport(snapshot: RewardsTrackerSnapshot) {
  const settings = snapshot.snapshot?.settings ?? {};
  return {
    cards: withoutCredentials(snapshot.cards),
    rules: withoutCredentials(snapshot.snapshot?.rules ?? []),
    tagMappings: withoutCredentials(snapshot.snapshot?.tagMappings ?? []),
    themeGroups: withoutCredentials(snapshot.snapshot?.themeGroups ?? []),
    hiddenCards: withoutCredentials(snapshot.snapshot?.hiddenCards ?? []),
    settings: withoutCredentials(Object.fromEntries([
      "currency", "milesValuation", "theme", "dashboardViewMode", "groupCardsByType",
      "cardOrdering", "collapsedCardGroups", "summaryViewSubcategoriesExpanded", "statementFormatter",
    ].filter((key) => settings[key] !== undefined).map((key) => [key, settings[key]]))),
  };
}

// Never copy connection settings or cached ledger data. Also strip credential
// fields embedded in older imported card/rule objects, which retain extra keys.
function withoutCredentials<T>(value: T): T {
  return JSON.parse(JSON.stringify(value, (key, entry) =>
    /token|secret|password|mnemonic|credential|api.?key|cloud.?sync|^pat$|^authorization$|^cachedData$/i.test(key) ? undefined : entry)) as T;
}
