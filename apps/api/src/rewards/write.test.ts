import { Database } from "bun:sqlite";
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { applyMigrations } from "../db";
import { LedgerRepository, NotFoundError, ValidationError } from "../repository";
import { parseCreditCardWrite } from "./parse";
import {
  createRewardsCard,
  deleteRewardsCard,
  patchRewardsCard,
  patchRewardsSettings,
  RewardsAccountError,
} from "./write";

let db: Database;
let repo: LedgerRepository;

beforeEach(async () => {
  db = new Database(":memory:");
  applyMigrations(db);
  repo = new LedgerRepository(db, "plan-test");
  await repo.upsertAccount("plan-test", { id: "acct-rewards", name: "Rewards Card", type: "creditCard" });
});

afterEach(() => {
  db.close();
});

describe("parseCreditCardWrite", () => {
  test("strips secrets and unknown keys", () => {
    const card = parseCreditCardWrite({
      id: "card-1",
      name: "Everyday",
      issuer: "DBS",
      type: "cashback",
      ynabAccountId: "acct-rewards",
      earningRate: 1.5,
      pat: "secret-pat",
      howmuchToken: "secret-howmuch",
      cachedData: { flagNames: {} },
      cloudSyncMnemonic: "one two three",
      settings: { cloudSyncMnemonic: "nested" },
    });

    expect(card).toEqual({
      id: "card-1",
      name: "Everyday",
      issuer: "DBS",
      type: "cashback",
      ynabAccountId: "acct-rewards",
      featured: true,
      earningRate: 1.5,
    });
    expect(card).not.toHaveProperty("pat");
    expect(card).not.toHaveProperty("howmuchToken");
    expect(card).not.toHaveProperty("cachedData");
    expect(card).not.toHaveProperty("cloudSyncMnemonic");
    expect(card).not.toHaveProperty("settings");
  });

  test("rejects a missing account id", () => {
    expect(() => parseCreditCardWrite({
      id: "card-1",
      name: "Everyday",
      issuer: "DBS",
      type: "cashback",
    })).toThrow(ValidationError);
  });
});

describe("native rewards card writes", () => {
  test("creates a card and a portable snapshot without wiping siblings", async () => {
    const first = await createRewardsCard(repo, "plan-test", {
      id: "card-cash",
      name: "Cash",
      issuer: "UOB",
      type: "cashback",
      ynabAccountId: "acct-rewards",
      earningRate: 1,
    });
    const second = await createRewardsCard(repo, "plan-test", {
      name: "Miles",
      issuer: "DBS",
      type: "miles",
      ynabAccountId: "acct-rewards",
      earningRate: 1.2,
    });

    expect(first.id).toBe("card-cash");
    expect(second.id).toStartWith("card_");
    const stored = await repo.getRewardsTrackerSnapshot("plan-test");
    expect(stored.cards).toEqual([
      expect.objectContaining({ id: "card-cash", type: "cashback" }),
      expect.objectContaining({ id: second.id, type: "miles" }),
    ]);
    expect((stored.snapshot as { cards: unknown[] }).cards).toHaveLength(2);
  });

  test("patches the same card id", async () => {
    await createRewardsCard(repo, "plan-test", {
      id: "card-cash",
      name: "Cash",
      type: "cashback",
      ynabAccountId: "acct-rewards",
      earningRate: 1,
    });
    const patched = await patchRewardsCard(repo, "plan-test", "card-cash", { earningRate: 3 });
    const again = await patchRewardsCard(repo, "plan-test", "card-cash", { earningRate: 3 });

    expect(patched).toMatchObject({ id: "card-cash", earningRate: 3, name: "Cash" });
    expect(again.id).toBe("card-cash");
    expect(db.query("SELECT COUNT(*) AS count FROM rewards_tracker_cards WHERE plan_id='plan-test' AND deleted=0").get()).toEqual({ count: 1 });
  });

  test("soft-deletes one card without emptying the snapshot", async () => {
    await createRewardsCard(repo, "plan-test", {
      id: "card-keep",
      name: "Keep",
      type: "cashback",
      ynabAccountId: "acct-rewards",
    });
    await createRewardsCard(repo, "plan-test", {
      id: "card-drop",
      name: "Drop",
      type: "cashback",
      ynabAccountId: "acct-rewards",
    });

    const deleted = await deleteRewardsCard(repo, "plan-test", "card-drop");
    expect(deleted).toMatchObject({ id: "card-drop", name: "Drop" });
    expect(await repo.deleteRewardsTrackerCard("plan-test", "card-drop")).toBeNull();
    await expect(deleteRewardsCard(repo, "plan-test", "card-drop")).rejects.toThrow(NotFoundError);

    const stored = await repo.getRewardsTrackerSnapshot("plan-test");
    expect(stored.cards).toEqual([expect.objectContaining({ id: "card-keep" })]);
    expect((stored.snapshot as { cards: Array<{ id: string }> }).cards.map((card) => card.id)).toEqual(["card-keep"]);
    expect(db.query("SELECT deleted FROM rewards_tracker_cards WHERE id='card-drop'").get()).toEqual({ deleted: 1 });
  });

  test("rejects an unknown account without writing a row", async () => {
    await expect(createRewardsCard(repo, "plan-test", {
      name: "Ghost",
      type: "cashback",
      ynabAccountId: "acct-missing",
    })).rejects.toThrow(RewardsAccountError);
    expect(db.query("SELECT COUNT(*) AS count FROM rewards_tracker_cards").get()).toEqual({ count: 0 });
  });

  test("rejects a missing account id", async () => {
    await expect(createRewardsCard(repo, "plan-test", {
      name: "Ghost",
      type: "cashback",
    })).rejects.toBeInstanceOf(RewardsAccountError);
    expect(db.query("SELECT COUNT(*) AS count FROM rewards_tracker_cards").get()).toEqual({ count: 0 });
  });

  test("replaces stored settings with the sanitised merge", async () => {
    await repo.upsertRewardsTrackerSnapshot("plan-test", {
      ynab: { trackedAccountIds: [] },
      cards: [],
      settings: { currency: "SGD", cloudSyncMnemonic: "keep-me-not" },
    });

    const settings = await patchRewardsSettings(repo, "plan-test", {
      milesValuation: 0.04,
      cloudSyncMnemonic: "do not store",
    });
    const stored = await repo.getRewardsTrackerSnapshot("plan-test");
    const snapshotSettings = (stored.snapshot as { settings: Record<string, unknown> }).settings;

    expect(settings).toMatchObject({ currency: "SGD", milesValuation: 0.04 });
    expect(snapshotSettings).toEqual({ currency: "SGD", milesValuation: 0.04 });
    expect(snapshotSettings).not.toHaveProperty("cloudSyncMnemonic");
  });

  test("treats a closed account as live", async () => {
    await repo.upsertAccount("plan-test", { id: "acct-closed", name: "Closed", type: "creditCard", closed: true });
    expect(await repo.findLiveAccountId("plan-test", "acct-closed")).toBe("acct-closed");
    const card = await createRewardsCard(repo, "plan-test", {
      name: "Closed card",
      type: "cashback",
      ynabAccountId: "acct-closed",
    });
    expect(card.ynabAccountId).toBe("acct-closed");
  });
});
