import type {
  AccountPreferences,
  AccountPreferencesSnapshot,
  AccountGroupSort,
  CustomAccountGroup,
} from "../api/types";

const BUILT_IN_GROUP_IDS = new Set(["favourites", "cash", "credit", "tracking", "closed"]);
const DANGEROUS_KEYS = new Set(["__proto__", "prototype", "constructor"]);

export type AccountPreferencesPhase = "idle" | "saving" | "error" | "unsupported";

export interface AccountPreferencesState {
  preferences: AccountPreferences;
  revision: number;
  phase: AccountPreferencesPhase;
  message: string | null;
}

interface AccountPreferencesClient {
  load: () => Promise<AccountPreferencesSnapshot | null>;
  save: (preferences: AccountPreferences, expectedRevision: number) => Promise<AccountPreferencesSnapshot>;
}

export function emptyAccountPreferences(): AccountPreferences {
  return {
    favourite_account_ids: [],
    account_order: [],
    account_order_by_group: {},
    account_group_sorts: {},
    custom_account_groups: [],
  };
}

export function normaliseAccountPreferences(preferences: AccountPreferences | null): AccountPreferences {
  if (!preferences) return emptyAccountPreferences();
  const groups: CustomAccountGroup[] = [];
  const usedIds = new Set<string>();
  for (const candidate of preferences.custom_account_groups) {
    const id = candidate.id.trim();
    const name = candidate.name.trim();
    if (!validCustomGroupId(id) || !name || name.length > 100 || usedIds.has(id)) {
      continue;
    }
    usedIds.add(id);
    groups.push({ id, name, account_ids: uniqueStrings(candidate.account_ids) });
  }
  const validGroupIds = new Set([...BUILT_IN_GROUP_IDS, ...groups.map((group) => group.id)]);
  const orderByGroup: Record<string, string[]> = {};
  for (const [groupId, order] of Object.entries(preferences.account_order_by_group)) {
    if (validGroupIds.has(groupId) && !DANGEROUS_KEYS.has(groupId.toLowerCase())) {
      orderByGroup[groupId] = uniqueStrings(order);
    }
  }
  const sorts: Record<string, AccountGroupSort> = {};
  for (const [groupId, sort] of Object.entries(preferences.account_group_sorts)) {
    if (validGroupIds.has(groupId) && ["manual", "alphabetical", "mostUsedLast30Days"].includes(sort)) {
      sorts[groupId] = sort;
    }
  }
  return {
    favourite_account_ids: uniqueStrings(preferences.favourite_account_ids),
    account_order: uniqueStrings(preferences.account_order),
    account_order_by_group: orderByGroup,
    account_group_sorts: sorts,
    custom_account_groups: groups,
  };
}

export function customAccountGroupNameError(
  preferences: AccountPreferences,
  name: string,
  excludingGroupId?: string,
): string | null {
  const trimmed = name.trim();
  if (!trimmed) return "Enter a group name.";
  if (trimmed.length > 100) return "Group names must be 100 characters or fewer.";
  const key = normalisedNameKey(trimmed);
  if (BUILT_IN_GROUP_IDS.has(key)) return "That name is reserved for a built-in group.";
  if (preferences.custom_account_groups.some((group) => group.id !== excludingGroupId && normalisedNameKey(group.name) === key)) {
    return "A custom group already uses that name.";
  }
  return null;
}

export function toggleFavouriteAccount(preferences: AccountPreferences, accountId: string): AccountPreferences {
  return setFavouriteAccount(preferences, accountId, !preferences.favourite_account_ids.includes(accountId));
}

export function setFavouriteAccount(
  preferences: AccountPreferences,
  accountId: string,
  selected: boolean,
): AccountPreferences {
  const alreadySelected = preferences.favourite_account_ids.includes(accountId);
  if (selected === alreadySelected) return preferences;
  return normaliseAccountPreferences({
    ...preferences,
    favourite_account_ids: selected
      ? [...preferences.favourite_account_ids, accountId]
      : preferences.favourite_account_ids.filter((id) => id !== accountId),
  });
}

export function addCustomAccountGroup(
  preferences: AccountPreferences,
  id: string,
  name: string,
): AccountPreferences {
  if (!validCustomGroupId(id) || preferences.custom_account_groups.some((group) => group.id === id)
    || customAccountGroupNameError(preferences, name)) {
    return preferences;
  }
  return normaliseAccountPreferences({
    ...preferences,
    custom_account_groups: [...preferences.custom_account_groups, { id, name: name.trim(), account_ids: [] }],
  });
}

export function renameCustomAccountGroup(
  preferences: AccountPreferences,
  groupId: string,
  name: string,
): AccountPreferences {
  if (customAccountGroupNameError(preferences, name, groupId)) return preferences;
  return normaliseAccountPreferences({
    ...preferences,
    custom_account_groups: preferences.custom_account_groups.map((group) =>
      group.id === groupId ? { ...group, name: name.trim() } : group),
  });
}

export function deleteCustomAccountGroup(preferences: AccountPreferences, groupId: string): AccountPreferences {
  const accountOrderByGroup = { ...preferences.account_order_by_group };
  const accountGroupSorts = { ...preferences.account_group_sorts };
  delete accountOrderByGroup[groupId];
  delete accountGroupSorts[groupId];
  return normaliseAccountPreferences({
    ...preferences,
    account_order_by_group: accountOrderByGroup,
    account_group_sorts: accountGroupSorts,
    custom_account_groups: preferences.custom_account_groups.filter((group) => group.id !== groupId),
  });
}

export function moveCustomAccountGroup(
  preferences: AccountPreferences,
  groupId: string,
  direction: -1 | 1,
): AccountPreferences {
  const index = preferences.custom_account_groups.findIndex((group) => group.id === groupId);
  const destination = index + direction;
  if (index < 0 || destination < 0 || destination >= preferences.custom_account_groups.length) return preferences;
  const groups = [...preferences.custom_account_groups];
  [groups[index], groups[destination]] = [groups[destination]!, groups[index]!];
  return { ...preferences, custom_account_groups: groups };
}

export function setAccountInCustomGroup(
  preferences: AccountPreferences,
  groupId: string,
  accountId: string,
  included: boolean,
): AccountPreferences {
  return normaliseAccountPreferences({
    ...preferences,
    custom_account_groups: preferences.custom_account_groups.map((group) => {
      if (group.id !== groupId) return group;
      const alreadyIncluded = group.account_ids.includes(accountId);
      if (included === alreadyIncluded) return group;
      return {
        ...group,
        account_ids: included
          ? [...group.account_ids, accountId]
          : group.account_ids.filter((id) => id !== accountId),
      };
    }),
  });
}

export function setAccountGroupSort(
  preferences: AccountPreferences,
  groupId: string,
  sort: AccountGroupSort,
): AccountPreferences {
  return normaliseAccountPreferences({
    ...preferences,
    account_group_sorts: { ...preferences.account_group_sorts, [groupId]: sort },
  });
}

export function moveAccountInGroup(
  preferences: AccountPreferences,
  groupId: string,
  orderedAccountIds: string[],
  accountId: string,
  direction: -1 | 1,
): AccountPreferences {
  const order = [...orderedAccountIds];
  const index = order.indexOf(accountId);
  const destination = index + direction;
  if (index < 0 || destination < 0 || destination >= order.length) return preferences;
  [order[index], order[destination]] = [order[destination]!, order[index]!];
  return normaliseAccountPreferences({
    ...preferences,
    account_order_by_group: { ...preferences.account_order_by_group, [groupId]: order },
  });
}

/** The same field-wise and custom-group three-way merge used by the iOS client. */
export function mergeAccountPreferences(
  baseline: AccountPreferences,
  local: AccountPreferences,
  remote: AccountPreferences,
): AccountPreferences {
  return normaliseAccountPreferences({
    favourite_account_ids: equal(local.favourite_account_ids, baseline.favourite_account_ids)
      ? remote.favourite_account_ids
      : local.favourite_account_ids,
    account_order: equal(local.account_order, baseline.account_order) ? remote.account_order : local.account_order,
    account_order_by_group: mergeMap(
      baseline.account_order_by_group,
      local.account_order_by_group,
      remote.account_order_by_group,
    ),
    account_group_sorts: mergeMap(
      baseline.account_group_sorts,
      local.account_group_sorts,
      remote.account_group_sorts,
    ),
    custom_account_groups: mergeCustomGroups(
      baseline.custom_account_groups,
      local.custom_account_groups,
      remote.custom_account_groups,
    ),
  });
}

/** Serialises optimistic writes and rebases them after revision conflicts. */
export class AccountPreferencesController {
  private baseline: { preferences: AccountPreferences; revision: number };
  private current: AccountPreferencesState;
  private dirty = false;
  private detached = false;
  private runPromise: Promise<void> | null = null;
  private onChange: ((state: AccountPreferencesState) => void) | null;

  constructor(
    snapshot: AccountPreferencesSnapshot,
    private readonly client: AccountPreferencesClient,
    onChange?: (state: AccountPreferencesState) => void,
  ) {
    const preferences = normaliseAccountPreferences(snapshot.account_preferences);
    this.baseline = { preferences, revision: snapshot.account_preferences_revision };
    this.current = { preferences, revision: snapshot.account_preferences_revision, phase: "idle", message: null };
    this.onChange = onChange ?? null;
  }

  get state(): AccountPreferencesState {
    return this.current;
  }

  update(updater: (preferences: AccountPreferences) => AccountPreferences): void {
    if (this.detached) return;
    const preferences = normaliseAccountPreferences(updater(this.current.preferences));
    if (equal(preferences, this.current.preferences)) return;
    this.dirty = true;
    this.setState(preferences, this.baseline.revision, "saving", "Saving account organisation…");
    this.start();
  }

  retry(): void {
    if (this.detached || !this.dirty || this.current.phase === "unsupported") return;
    this.setState(this.current.preferences, this.baseline.revision, "saving", "Retrying account organisation…");
    this.start();
  }

  async settled(): Promise<void> {
    while (this.runPromise) await this.runPromise;
  }

  detach(): void {
    this.detached = true;
    this.onChange = null;
  }

  private start(): void {
    if (this.runPromise) return;
    const run = this.flush();
    this.runPromise = run;
    void run.finally(() => {
      if (this.runPromise === run) this.runPromise = null;
    });
  }

  private async flush(): Promise<void> {
    let mergedConflict = false;
    let conflictAttempts = 0;
    while (this.dirty) {
      this.dirty = false;
      const target = this.current.preferences;
      try {
        const saved = await this.client.save(target, this.baseline.revision);
        if (this.detached) return;
        if (!saved.account_preferences) throw new Error("The server returned empty account preferences after saving.");
        this.baseline = {
          preferences: normaliseAccountPreferences(saved.account_preferences),
          revision: saved.account_preferences_revision,
        };
        this.dirty = !equal(this.current.preferences, target);
        if (!this.dirty) {
          this.setState(
            this.baseline.preferences,
            this.baseline.revision,
            "idle",
            mergedConflict ? "Saved after merging changes from another client." : "Account organisation saved.",
          );
        } else {
          this.setState(this.current.preferences, this.baseline.revision, "saving", "Saving newer account changes…");
        }
      } catch (cause) {
        if (this.detached) return;
        if (isConflict(cause) && conflictAttempts < 3) {
          conflictAttempts += 1;
          try {
            const remoteSnapshot = await this.client.load();
            if (this.detached) return;
            if (!remoteSnapshot) {
              this.dirty = true;
              this.setState(
                this.current.preferences,
                this.baseline.revision,
                "unsupported",
                "This server does not support synced account organisation. Your latest change was not saved.",
              );
              return;
            }
            const remote = normaliseAccountPreferences(remoteSnapshot.account_preferences);
            const merged = mergeAccountPreferences(this.baseline.preferences, this.current.preferences, remote);
            this.baseline = { preferences: remote, revision: remoteSnapshot.account_preferences_revision };
            this.dirty = !equal(merged, remote);
            mergedConflict = true;
            this.setState(merged, this.baseline.revision, this.dirty ? "saving" : "idle",
              this.dirty ? "Merged changes from another client; saving…" : "Loaded changes from another client.");
          } catch (loadCause) {
            this.fail(loadCause);
            return;
          }
          continue;
        }
        if (isUnsupported(cause)) {
          this.dirty = true;
          this.setState(
            this.current.preferences,
            this.baseline.revision,
            "unsupported",
            "This server does not support synced account organisation. Your latest change was not saved.",
          );
          return;
        }
        if (isConflict(cause)) {
          this.dirty = true;
          this.setState(
            this.current.preferences,
            this.baseline.revision,
            "error",
            "Account organisation kept changing on another client. Retry to merge the latest version.",
          );
          return;
        }
        this.fail(cause);
        return;
      }
    }
  }

  private fail(cause: unknown): void {
    this.dirty = true;
    this.setState(
      this.current.preferences,
      this.baseline.revision,
      "error",
      cause instanceof Error ? cause.message : String(cause),
    );
  }

  private setState(
    preferences: AccountPreferences,
    revision: number,
    phase: AccountPreferencesPhase,
    message: string | null,
  ): void {
    this.current = { preferences, revision, phase, message };
    this.onChange?.(this.current);
  }
}

function mergeMap<Value>(
  baseline: Record<string, Value>,
  local: Record<string, Value>,
  remote: Record<string, Value>,
): Record<string, Value> {
  const result = { ...remote };
  for (const key of new Set([...Object.keys(baseline), ...Object.keys(local)])) {
    if (!equal(local[key], baseline[key])) {
      if (Object.hasOwn(local, key)) result[key] = local[key]!;
      else delete result[key];
    }
  }
  return result;
}

function mergeCustomGroups(
  baseline: CustomAccountGroup[],
  local: CustomAccountGroup[],
  remote: CustomAccountGroup[],
): CustomAccountGroup[] {
  const baselineById = new Map(baseline.map((group) => [group.id, group]));
  const localById = new Map(local.map((group) => [group.id, group]));
  const remoteById = new Map(remote.map((group) => [group.id, group]));
  const localChangedOrder = !equal(local.map((group) => group.id), baseline.map((group) => group.id));
  const preferredOrder = localChangedOrder
    ? [...local.map((group) => group.id), ...remote.map((group) => group.id).filter((id) => !baselineById.has(id) && !localById.has(id))]
    : remote.map((group) => group.id);
  return preferredOrder.flatMap((id) => {
    const localGroup = localById.get(id);
    const selected = !equal(localGroup, baselineById.get(id)) ? localGroup : remoteById.get(id);
    return selected ? [selected] : [];
  });
}

function uniqueStrings(values: string[]): string[] {
  const result: string[] = [];
  const seen = new Set<string>();
  for (const value of values) {
    const trimmed = value.trim();
    if (trimmed && !seen.has(trimmed)) {
      seen.add(trimmed);
      result.push(trimmed);
    }
  }
  return result;
}

function validCustomGroupId(id: string): boolean {
  const key = id.toLowerCase();
  return Boolean(id) && id.length <= 200 && id === id.trim() && !BUILT_IN_GROUP_IDS.has(key) && !DANGEROUS_KEYS.has(key);
}

function normalisedNameKey(name: string): string {
  return name.trim().normalize("NFD").replace(/\p{Diacritic}/gu, "").toLocaleLowerCase();
}

function equal(first: unknown, second: unknown): boolean {
  return JSON.stringify(first) === JSON.stringify(second);
}

function isConflict(cause: unknown): boolean {
  return cause instanceof Error
    && "status" in cause
    && cause.status === 409
    && (!("code" in cause) || cause.code === "account_preferences_conflict");
}

function isUnsupported(cause: unknown): boolean {
  return cause instanceof Error && "status" in cause && cause.status === 404;
}
