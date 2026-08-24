import { describe, expect, test } from "bun:test";
import type { AccountPreferences, AccountPreferencesSnapshot } from "../api/types";
import {
  AccountPreferencesController,
  addCustomAccountGroup,
  customAccountGroupNameError,
  deleteCustomAccountGroup,
  emptyAccountPreferences,
  mergeAccountPreferences,
  moveAccountInGroup,
  moveCustomAccountGroup,
  normaliseAccountPreferences,
  renameCustomAccountGroup,
  setAccountGroupSort,
  setAccountInCustomGroup,
  toggleFavouriteAccount,
} from "./account-preferences";

function snapshot(accountPreferences: AccountPreferences, revision: number): AccountPreferencesSnapshot {
  return {
    account_preferences: accountPreferences,
    account_preferences_revision: revision,
  };
}

describe("account preference editing", () => {
  test("edits favourites, custom groups, membership, group order, and manual account order", () => {
    let preferences = toggleFavouriteAccount(emptyAccountPreferences(), "cash");
    preferences = addCustomAccountGroup(preferences, "custom-travel", " Travel ");
    preferences = addCustomAccountGroup(preferences, "custom-shared", "Shared");
    preferences = setAccountInCustomGroup(preferences, "custom-travel", "cash", true);
    preferences = setAccountInCustomGroup(preferences, "custom-travel", "card", true);
    preferences = renameCustomAccountGroup(preferences, "custom-travel", "Trips");
    preferences = moveCustomAccountGroup(preferences, "custom-shared", -1);
    preferences = setAccountGroupSort(preferences, "custom-travel", "manual");
    preferences = moveAccountInGroup(preferences, "custom-travel", ["cash", "card"], "card", -1);

    expect(preferences.favourite_account_ids).toEqual(["cash"]);
    expect(preferences.custom_account_groups).toEqual([
      { id: "custom-shared", name: "Shared", account_ids: [] },
      { id: "custom-travel", name: "Trips", account_ids: ["cash", "card"] },
    ]);
    expect(preferences.account_order_by_group["custom-travel"]).toEqual(["card", "cash"]);

    preferences = deleteCustomAccountGroup(preferences, "custom-travel");
    expect(preferences.custom_account_groups.map((group) => group.id)).toEqual(["custom-shared"]);
    expect(preferences.account_group_sorts["custom-travel"]).toBeUndefined();
    expect(preferences.account_order_by_group["custom-travel"]).toBeUndefined();
  });

  test("matches iOS validation for duplicate and reserved custom group names", () => {
    const preferences = addCustomAccountGroup(emptyAccountPreferences(), "custom-travel", "Trável");
    expect(customAccountGroupNameError(preferences, " Cash ")).toBe("That name is reserved for a built-in group.");
    expect(customAccountGroupNameError(preferences, "travel")).toBe("A custom group already uses that name.");
    expect(customAccountGroupNameError(preferences, "   ")).toBe("Enter a group name.");
    expect(customAccountGroupNameError(preferences, "Trips")).toBeNull();
  });

  test("preserves legacy accent-colliding groups so an edit cannot silently delete them", () => {
    const preferences = normaliseAccountPreferences({
      ...emptyAccountPreferences(),
      custom_account_groups: [
        { id: "custom-travel", name: "Travel", account_ids: [] },
        { id: "custom-travel-accent", name: "Trável", account_ids: [] },
        { id: "custom-cash", name: "Cásh", account_ids: [] },
      ],
    });

    expect(preferences.custom_account_groups.map((group) => group.name)).toEqual(["Travel", "Trável", "Cásh"]);
    expect(customAccountGroupNameError(preferences, "Trips", "custom-travel-accent")).toBeNull();
  });
});

describe("account preference conflict merge", () => {
  test("preserves local field edits while accepting unrelated remote edits and groups", () => {
    const baseline: AccountPreferences = {
      ...emptyAccountPreferences(),
      favourite_account_ids: ["cash"],
      account_group_sorts: { cash: "manual" },
      custom_account_groups: [{ id: "custom-travel", name: "Travel", account_ids: ["cash"] }],
    };
    const local: AccountPreferences = {
      ...baseline,
      favourite_account_ids: ["cash", "card"],
      custom_account_groups: [
        { id: "custom-local", name: "Local", account_ids: [] },
        baseline.custom_account_groups[0]!,
      ],
    };
    const remote: AccountPreferences = {
      ...baseline,
      favourite_account_ids: ["loan"],
      account_group_sorts: { cash: "alphabetical" },
      custom_account_groups: [
        { id: "custom-travel", name: "Trips", account_ids: ["cash", "card"] },
        { id: "custom-remote", name: "Remote", account_ids: ["loan"] },
      ],
    };

    expect(mergeAccountPreferences(baseline, local, remote)).toEqual({
      ...remote,
      favourite_account_ids: ["cash", "card"],
      custom_account_groups: [
        { id: "custom-local", name: "Local", account_ids: [] },
        { id: "custom-travel", name: "Trips", account_ids: ["cash", "card"] },
        { id: "custom-remote", name: "Remote", account_ids: ["loan"] },
      ],
    });
  });
});

describe("AccountPreferencesController", () => {
  test("a detached controller cannot conflict-retry over its replacement", async () => {
    let releaseWrite!: () => void;
    const writeGate = new Promise<void>((resolve) => { releaseWrite = resolve; });
    let writeStarted!: () => void;
    const started = new Promise<void>((resolve) => { writeStarted = resolve; });
    let loadCount = 0;
    let saveCount = 0;
    const controller = new AccountPreferencesController(snapshot(emptyAccountPreferences(), 1), {
      load: async () => {
        loadCount += 1;
        return snapshot(emptyAccountPreferences(), 2);
      },
      save: async () => {
        saveCount += 1;
        writeStarted();
        await writeGate;
        throw Object.assign(new Error("conflict"), { status: 409, code: "account_preferences_conflict" });
      },
    });

    controller.update((preferences) => toggleFavouriteAccount(preferences, "cash"));
    await started;
    controller.detach();
    releaseWrite();
    await controller.settled();

    expect(saveCount).toBe(1);
    expect(loadCount).toBe(0);
  });

  test("uses revision CAS, refetches on conflict, and merges edits made during the request", async () => {
    const initial = emptyAccountPreferences();
    const remote = {
      ...initial,
      account_group_sorts: { cash: "alphabetical" as const },
    };
    const writes: Array<{ preferences: AccountPreferences; expectedRevision: number }> = [];
    let releaseFirstWrite!: () => void;
    const firstWriteGate = new Promise<void>((resolve) => { releaseFirstWrite = resolve; });
    let firstWriteStarted!: () => void;
    const started = new Promise<void>((resolve) => { firstWriteStarted = resolve; });
    let writeCount = 0;

    const controller = new AccountPreferencesController(snapshot(initial, 1), {
      load: async () => snapshot(remote, 2),
      save: async (preferences, expectedRevision) => {
        writes.push({ preferences, expectedRevision });
        writeCount += 1;
        if (writeCount === 1) {
          firstWriteStarted();
          await firstWriteGate;
          throw Object.assign(new Error("conflict"), { status: 409, code: "account_preferences_conflict" });
        }
        return snapshot(preferences, expectedRevision + 1);
      },
    });

    controller.update((preferences) => toggleFavouriteAccount(preferences, "cash"));
    await started;
    controller.update((preferences) => toggleFavouriteAccount(preferences, "card"));
    expect(controller.state.preferences.favourite_account_ids).toEqual(["cash", "card"]);
    releaseFirstWrite();
    await controller.settled();

    expect(writes).toHaveLength(2);
    expect(writes.map((write) => write.expectedRevision)).toEqual([1, 2]);
    expect(writes[1]!.preferences.favourite_account_ids).toEqual(["cash", "card"]);
    expect(writes[1]!.preferences.account_group_sorts).toEqual({ cash: "alphabetical" });
    expect(controller.state).toMatchObject({ phase: "idle", revision: 3 });
    expect(controller.state.message).toContain("another client");
  });

  test("keeps optimistic state after an error and retries it against the same revision", async () => {
    const writes: number[] = [];
    let failing = true;
    const controller = new AccountPreferencesController(snapshot(emptyAccountPreferences(), 4), {
      load: async () => {
        throw new Error("not used");
      },
      save: async (preferences, expectedRevision) => {
        writes.push(expectedRevision);
        if (failing) throw new Error("Network unavailable");
        return snapshot(preferences, expectedRevision + 1);
      },
    });

    controller.update((preferences) => toggleFavouriteAccount(preferences, "cash"));
    await controller.settled();
    expect(controller.state).toMatchObject({ phase: "error", revision: 4 });
    expect(controller.state.preferences.favourite_account_ids).toEqual(["cash"]);

    failing = false;
    controller.retry();
    await controller.settled();
    expect(writes).toEqual([4, 4]);
    expect(controller.state).toMatchObject({ phase: "idle", revision: 5 });
  });

  test("keeps the sidebar edit local when an older server rejects the write endpoint", async () => {
    const controller = new AccountPreferencesController(snapshot(emptyAccountPreferences(), 0), {
      load: async () => null,
      save: async () => {
        throw Object.assign(new Error("Route not found"), { status: 404 });
      },
    });

    controller.update((preferences) => toggleFavouriteAccount(preferences, "cash"));
    await controller.settled();

    expect(controller.state).toMatchObject({ phase: "unsupported", revision: 0 });
    expect(controller.state.preferences.favourite_account_ids).toEqual(["cash"]);
    expect(controller.state.message).toContain("does not support");
  });
});
