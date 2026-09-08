import type { Account } from "../api/types";

const CREDIT_TYPES = new Set(["creditCard", "lineOfCredit"]);

export function isRewardCardAccountType(type: string | null | undefined): boolean {
  return CREDIT_TYPES.has(type ?? "");
}

/** Credit and LOC accounts that are not already mapped, plus the card's current account. */
export function rewardCardAccountChoices(
  accounts: Account[],
  takenIds: Iterable<string>,
  keepId?: string,
): Account[] {
  const taken = new Set(takenIds);
  return accounts
    .filter((account) => {
      if (account.deleted) return false;
      if (keepId && account.id === keepId) return true;
      if (taken.has(account.id)) return false;
      return isRewardCardAccountType(account.type);
    })
    .sort((left, right) => {
      if (left.closed !== right.closed) return left.closed ? 1 : -1;
      return left.name.localeCompare(right.name, "en-GB");
    });
}

/** Keep a nickname; otherwise follow the selected HowMuch card's name. */
export function syncedRewardCardName(options: {
  name: string;
  previousAccountName?: string | null;
  nextAccountName?: string | null;
}): string {
  const trimmed = options.name.trim();
  const wasSynced = !trimmed || trimmed === (options.previousAccountName ?? "");
  if (!wasSynced) return options.name;
  return options.nextAccountName ?? "";
}
