import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import {
  REFERENCE_CACHE_VERSION,
  clearReferenceCache,
  currentCacheEpoch,
  decideReferenceRefresh,
  deserialiseEnvelope,
  makeEnvelope,
  planCachedFetch,
  readSlot,
  serialiseEnvelope,
  shouldUseCache,
  slotKey,
  validateAgainstKnowledge,
  writeSlot,
} from "./reference-cache";
import { isCachedPayees, isCachedReference, isCachedRegisterPage } from "./cache-shapes";

// Everything here is synthetic: invented ids, invented names, invented
// amounts. No ledger row, payee or memo from any real plan appears.
const identity = { userId: "user-1", planId: "plan-1" };

const payees = [
  { id: "payee-1", name: "Synthetic Grocer" },
  { id: "payee-2", name: "Synthetic Utility" },
];

const reference = {
  settings: { currency_format: { iso_code: "SGD" } },
  categoryGroups: [{ id: "group-1", name: "Everyday", categories: [{ id: "category-1" }] }],
  accounts: [{ id: "account-1", name: "Test Account", balance: 1000 }],
  accountPreferences: null,
};

function isPayeeList(value: unknown): value is typeof payees {
  return isCachedPayees(value);
}

/** A minimal `localStorage` so the shell can be exercised under bun test. */
function installStorage(): Map<string, string> {
  const store = new Map<string, string>();
  (globalThis as Record<string, unknown>).localStorage = {
    getItem: (key: string) => store.get(key) ?? null,
    setItem: (key: string, value: string) => void store.set(key, String(value)),
    removeItem: (key: string) => void store.delete(key),
    clear: () => store.clear(),
  };
  return store;
}

describe("validateAgainstKnowledge", () => {
  test("equal knowledge is fresh", () => {
    expect(validateAgainstKnowledge(41, 41)).toBe("fresh");
  });

  test("a write from another client advances knowledge", () => {
    expect(validateAgainstKnowledge(41, 42)).toBe("advanced");
  });

  test("knowledge that went backwards is not trusted either", () => {
    expect(validateAgainstKnowledge(42, 41)).toBe("advanced");
  });
});

describe("shouldUseCache", () => {
  test("accepts an entry for this user and plan", () => {
    expect(shouldUseCache(makeEnvelope(identity, 1, payees), identity)).toBe(true);
  });

  test("rejects another user's entry even when the plan and knowledge match", () => {
    const envelope = makeEnvelope({ userId: "user-2", planId: "plan-1" }, 1, payees);
    expect(shouldUseCache(envelope, identity)).toBe(false);
  });

  test("rejects an entry for another plan", () => {
    const envelope = makeEnvelope({ userId: "user-1", planId: "plan-2" }, 1, payees);
    expect(shouldUseCache(envelope, identity)).toBe(false);
  });

  test("rejects nothing at all", () => {
    expect(shouldUseCache(null, identity)).toBe(false);
  });
});

describe("planCachedFetch", () => {
  test("equal knowledge keeps the cached set and makes no request", () => {
    const plan = planCachedFetch(makeEnvelope(identity, 41, payees), identity, 41);
    expect(plan).toEqual({ use: "cache", value: payees });
  });

  test("a write from another client replaces the cached set", () => {
    // Cached at N, server reports N+1: the entry may only seed the fetch.
    const plan = planCachedFetch(makeEnvelope(identity, 41, payees), identity, 42);
    expect(plan).toEqual({ use: "network", seed: payees });
  });

  test("waits for the knowledge check rather than fetching blind", () => {
    const plan = planCachedFetch(makeEnvelope(identity, 41, payees), identity, null);
    expect(plan).toEqual({ use: "wait", seed: payees });
  });

  test("fetches with nothing to show when there is no usable entry", () => {
    expect(planCachedFetch(null, identity, 41)).toEqual({ use: "network", seed: null });
  });

  test("another user's entry is never seeded, let alone kept", () => {
    const envelope = makeEnvelope({ userId: "user-2", planId: "plan-1" }, 41, payees);
    expect(planCachedFetch(envelope, identity, 41)).toEqual({ use: "network", seed: null });
  });
});

describe("decideReferenceRefresh", () => {
  test("keeps the cached accounts when knowledge has not moved", () => {
    expect(decideReferenceRefresh(makeEnvelope(identity, 7, reference), identity, 7)).toBe("keep");
  });

  test("refetches when knowledge has moved", () => {
    expect(decideReferenceRefresh(makeEnvelope(identity, 7, reference), identity, 8)).toBe("refetch");
  });

  test("refetches when the server reports no knowledge at all", () => {
    expect(decideReferenceRefresh(makeEnvelope(identity, 7, reference), identity, null)).toBe("refetch");
  });
});

describe("deserialiseEnvelope", () => {
  test("round-trips an envelope", () => {
    const envelope = makeEnvelope(identity, 41, payees);
    expect(deserialiseEnvelope(serialiseEnvelope(envelope), isPayeeList)).toEqual(envelope);
  });

  test("ignores corrupt JSON", () => {
    expect(deserialiseEnvelope("{not json", isPayeeList)).toBeNull();
  });

  test("ignores a truncated write", () => {
    const raw = serialiseEnvelope(makeEnvelope(identity, 41, payees));
    expect(deserialiseEnvelope(raw.slice(0, raw.length - 12), isPayeeList)).toBeNull();
  });

  test("ignores an envelope written by an older schema version", () => {
    const stale = JSON.stringify({
      ...makeEnvelope(identity, 41, payees),
      version: REFERENCE_CACHE_VERSION - 1,
    });
    expect(deserialiseEnvelope(stale, isPayeeList)).toBeNull();
  });

  test("ignores a payload the guard rejects", () => {
    const wrongShape = serialiseEnvelope(makeEnvelope(identity, 41, [{ nope: true }] as never));
    expect(deserialiseEnvelope(wrongShape, isPayeeList)).toBeNull();
  });

  test("ignores an envelope missing its identity", () => {
    const headless = JSON.stringify({ version: REFERENCE_CACHE_VERSION, serverKnowledge: 1, data: payees });
    expect(deserialiseEnvelope(headless, isPayeeList)).toBeNull();
  });

  test("ignores nothing at all", () => {
    expect(deserialiseEnvelope(null, isPayeeList)).toBeNull();
  });
});

describe("the storage shell", () => {
  let store: Map<string, string>;

  beforeEach(() => {
    store = installStorage();
  });

  afterEach(() => {
    delete (globalThis as Record<string, unknown>).localStorage;
  });

  test("a written slot reads back with its knowledge", () => {
    writeSlot("payees", identity, 41, payees);
    expect(readSlot("payees", isPayeeList)?.serverKnowledge).toBe(41);
  });

  test("signing out clears every slot", () => {
    writeSlot("payees", identity, 41, payees);
    writeSlot("reference", identity, 41, reference);
    writeSlot("scheduled", identity, 41, []);
    writeSlot("register", identity, 41, {
      listKey: "list-1",
      transactions: [{ id: "txn-1", date: "2026-01-01", amount: -1000, account_id: "account-1" }],
      hasMore: false,
      nextOffset: null,
    });
    expect(store.size).toBe(4);

    clearReferenceCache();

    expect(store.size).toBe(0);
    expect(readSlot("payees", isPayeeList)).toBeNull();
    expect(readSlot("reference", isCachedReference)).toBeNull();
    expect(readSlot("register", isCachedRegisterPage)).toBeNull();
  });

  test("a slot corrupted in place is ignored rather than thrown", () => {
    writeSlot("payees", identity, 41, payees);
    store.set(slotKey("payees"), "<!doctype html>");
    expect(readSlot("payees", isPayeeList)).toBeNull();
  });

  test("a write from another client is seen on the next load and replaces the entry", () => {
    writeSlot("reference", identity, 41, reference);

    // The plans list, which the bootstrap already fetches, now reports 42.
    const cached = readSlot("reference", isCachedReference);
    expect(decideReferenceRefresh(cached, identity, 42)).toBe("refetch");

    // The refetched set is stored under the knowledge it was read at, and the
    // old accounts are gone.
    const refreshed = { ...reference, accounts: [{ id: "account-1", name: "Test Account", balance: 2000 }] };
    writeSlot("reference", identity, 42, refreshed);
    const reread = readSlot("reference", isCachedReference);
    expect(reread?.serverKnowledge).toBe(42);
    expect(reread?.data.accounts[0]?.balance).toBe(2000);
    expect(decideReferenceRefresh(reread, identity, 42)).toBe("keep");
  });

  test("a read that started before a local write cannot refill the cache", () => {
    // The GET went out at this epoch and resolves after the write below.
    const epochAtRequest = currentCacheEpoch();
    writeSlot("payees", identity, 41, payees);
    expect(readSlot("payees", isPayeeList)).not.toBeNull();

    clearReferenceCache();
    expect(readSlot("payees", isPayeeList)).toBeNull();

    // Its rows predate the write, so storing them would resurrect exactly what
    // the invalidation existed to remove.
    writeSlot("payees", identity, 41, payees, epochAtRequest);
    expect(readSlot("payees", isPayeeList)).toBeNull();

    // A read started after the invalidation stores normally.
    writeSlot("payees", identity, 42, payees, currentCacheEpoch());
    expect(readSlot("payees", isPayeeList)?.serverKnowledge).toBe(42);
  });

  test("every invalidation moves the epoch", () => {
    const before = currentCacheEpoch();
    clearReferenceCache();
    const once = currentCacheEpoch();
    expect(once).toBeGreaterThan(before);
    clearReferenceCache();
    expect(currentCacheEpoch()).toBeGreaterThan(once);
  });

  test("unusable storage is survivable: reads return nothing, writes do not throw", () => {
    (globalThis as Record<string, unknown>).localStorage = {
      getItem: () => { throw new Error("storage unavailable"); },
      setItem: () => { throw new Error("storage unavailable"); },
      removeItem: () => { throw new Error("storage unavailable"); },
    };
    expect(readSlot("payees", isPayeeList)).toBeNull();
    expect(() => writeSlot("payees", identity, 1, payees)).not.toThrow();
    expect(() => clearReferenceCache()).not.toThrow();
  });
});
