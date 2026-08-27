import { graphemes, parseAccountIcon } from "../../apps/api/src/account-icon";

export type HowMuchAccountRef = {
  id: string;
  external_ynab_id?: string | null;
  icon?: string | null;
};

export type YnabAccountRef = {
  id: string;
  name: string;
  deleted?: boolean;
};

export type IconRestoreUpdate = {
  howmuchId: string;
  icon: string;
};

export type IconRestorePlan = {
  updates: IconRestoreUpdate[];
  ynabAccounts: number;
  ynabWithLeadingIcon: number;
  matched: number;
  alreadySet: number;
  unmatchedYnabWithIcon: number;
  skippedDeleted: number;
  skippedNoIcon: number;
};

const SAFE_ID = /^[A-Za-z0-9_-]+$/;

export function planIconRestoreFromYnab(
  ynabAccounts: YnabAccountRef[],
  howmuchAccounts: HowMuchAccountRef[],
): IconRestorePlan {
  const byId = new Map<string, HowMuchAccountRef>();
  for (const row of howmuchAccounts) {
    byId.set(row.id, row);
    if (row.external_ynab_id) byId.set(row.external_ynab_id, row);
  }

  const updates: IconRestoreUpdate[] = [];
  const seenHowmuch = new Set<string>();
  let ynabWithLeadingIcon = 0;
  let matched = 0;
  let alreadySet = 0;
  let unmatchedYnabWithIcon = 0;
  let skippedDeleted = 0;
  let skippedNoIcon = 0;

  for (const account of ynabAccounts) {
    if (account.deleted) {
      skippedDeleted += 1;
      continue;
    }
    const icon = leadingIconFromYnabName(account.name);
    if (!icon || !parseAccountIcon(icon)) {
      skippedNoIcon += 1;
      continue;
    }
    ynabWithLeadingIcon += 1;
    const row = byId.get(account.id);
    if (!row) {
      unmatchedYnabWithIcon += 1;
      continue;
    }
    matched += 1;
    if (row.icon === icon || seenHowmuch.has(row.id)) {
      alreadySet += 1;
      continue;
    }
    seenHowmuch.add(row.id);
    updates.push({ howmuchId: row.id, icon });
  }

  return {
    updates,
    ynabAccounts: ynabAccounts.length,
    ynabWithLeadingIcon,
    matched,
    alreadySet,
    unmatchedYnabWithIcon,
    skippedDeleted,
    skippedNoIcon,
  };
}

export function sqlForIconRestore(updates: IconRestoreUpdate[]): string {
  if (updates.length === 0) {
    return "SELECT 0 AS icon_updates;\n";
  }
  const statements = updates.map((update) => {
    if (!SAFE_ID.test(update.howmuchId)) {
      throw new Error("refusing to write an unsafe account id");
    }
    const icon = parseAccountIcon(update.icon);
    if (!icon) {
      throw new Error("refusing to write a non-emoji icon");
    }
    return `UPDATE accounts SET icon = '${escapeSql(icon)}', updated_at = CURRENT_TIMESTAMP WHERE deleted = 0 AND id = '${update.howmuchId}';`;
  });
  return [
    "BEGIN;",
    ...statements,
    "UPDATE plans SET server_knowledge = server_knowledge + 1, updated_at = CURRENT_TIMESTAMP;",
    "COMMIT;",
    "",
  ].join("\n");
}

function leadingIconFromYnabName(name: string): string | null {
  const trimmed = name.trim();
  const parts = graphemes(trimmed);
  if (parts.length === 0) return null;
  return parseAccountIcon(parts[0]!);
}

function escapeSql(value: string): string {
  return value.replaceAll("'", "''");
}
