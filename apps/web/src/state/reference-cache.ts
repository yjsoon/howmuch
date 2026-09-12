/**
 * A validated client cache, keyed on `server_knowledge`.
 *
 * #144 forbids stale caches, so nothing here is trusted on age. Every entry
 * records the `server_knowledge` it was fetched at, plus the user and plan it
 * belongs to. On load the app paints from the entry immediately and marks that
 * paint provisional; `GET /v1/plans` — which the bootstrap already fetches and
 * which already carries `server_knowledge` — is the knowledge check. An entry
 * survives only when its knowledge equals the server's.
 *
 * Coverage is not uniform, and the distinction matters:
 *
 * - Validated. Accounts, payees, scheduled transactions and the register all
 *   sit behind writes that bump `server_knowledge` — `touchPlan`,
 *   `persistScheduledTransaction` and `executeMutationPlan` in the repository,
 *   and, since this cache exists to rely on it, `upsertAccount` and
 *   `upsertPayee`, which importers use and which previously changed those
 *   lists silently. Equal knowledge therefore proves the entry is current, so
 *   the refetch is skipped.
 * - Provisional only. Plan settings (`upsertPlan`), categories
 *   (`upsertCategory`) and account preferences (its own `revision`) change
 *   without touching `server_knowledge`. They are painted from cache for the
 *   first frame and then always refetched; equal knowledge proves nothing
 *   about them.
 *
 * The decisions live here as pure functions so the discard branches can be
 * tested directly. The last section is a thin `localStorage` shell.
 */

/** Bump when a cached shape changes; older entries are then ignored. */
export const REFERENCE_CACHE_VERSION = 1;

const KEY_PREFIX = `howmuch.cache.v${REFERENCE_CACHE_VERSION}.`;

/** Who and what an entry was fetched for. A mismatch discards it. */
export interface CacheIdentity {
  userId: string;
  planId: string;
}

export interface CacheEnvelope<T> {
  version: number;
  userId: string;
  planId: string;
  serverKnowledge: number;
  data: T;
}

export type KnowledgeVerdict = "fresh" | "advanced";

/** What a cached slot lets a fetch site do. */
export type CachedFetchPlan<T> =
  | { use: "cache"; value: T }
  | { use: "wait"; seed: T }
  | { use: "network"; seed: T | null };

export function makeEnvelope<T>(
  identity: CacheIdentity,
  serverKnowledge: number,
  data: T,
): CacheEnvelope<T> {
  return {
    version: REFERENCE_CACHE_VERSION,
    userId: identity.userId,
    planId: identity.planId,
    serverKnowledge,
    data,
  };
}

export function serialiseEnvelope<T>(envelope: CacheEnvelope<T>): string {
  return JSON.stringify(envelope);
}

/**
 * Read an envelope back, or null for anything that is not exactly one.
 *
 * Corrupt JSON, a truncated write, an envelope from an older code version and
 * a payload the guard rejects all take the same branch: there is no cache.
 */
export function deserialiseEnvelope<T>(
  raw: string | null | undefined,
  guard: (value: unknown) => value is T,
): CacheEnvelope<T> | null {
  if (typeof raw !== "string" || raw === "") {
    return null;
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return null;
  }
  const value = parsed as Record<string, unknown>;
  if (value.version !== REFERENCE_CACHE_VERSION) {
    return null;
  }
  if (typeof value.userId !== "string" || value.userId === "") {
    return null;
  }
  if (typeof value.planId !== "string" || value.planId === "") {
    return null;
  }
  if (typeof value.serverKnowledge !== "number" || !Number.isFinite(value.serverKnowledge)) {
    return null;
  }
  if (!guard(value.data)) {
    return null;
  }
  return {
    version: REFERENCE_CACHE_VERSION,
    userId: value.userId,
    planId: value.planId,
    serverKnowledge: value.serverKnowledge,
    data: value.data,
  };
}

/** Whether an entry belongs to this user, this plan and this code version. */
export function shouldUseCache<T>(
  envelope: CacheEnvelope<T> | null,
  identity: CacheIdentity,
): boolean {
  if (!envelope) return false;
  return envelope.version === REFERENCE_CACHE_VERSION
    && envelope.userId === identity.userId
    && envelope.planId === identity.planId;
}

/**
 * Compare cached knowledge with the server's.
 *
 * Anything other than an exact match is "advanced": a lower number means
 * another client wrote, and a higher one means the entry came from a ledger
 * this server no longer has. Both must refetch.
 */
export function validateAgainstKnowledge(cached: number, server: number): KnowledgeVerdict {
  return cached === server ? "fresh" : "advanced";
}

/**
 * Decide a validated slot.
 *
 * - No usable entry: fetch, with nothing to show meanwhile. The cold path.
 * - An entry, but the plan's knowledge is not known yet: show it and wait. The
 *   check is one response away and is already in flight, so fetching now would
 *   throw away the saving the check exists to make.
 * - Knowledge equal: the entry is provably current. No request at all.
 * - Knowledge moved: fetch, showing the entry as a seed until it lands.
 */
export function planCachedFetch<T>(
  envelope: CacheEnvelope<T> | null,
  identity: CacheIdentity,
  serverKnowledge: number | null,
): CachedFetchPlan<T> {
  if (!envelope || !shouldUseCache(envelope, identity)) {
    return { use: "network", seed: null };
  }
  if (serverKnowledge === null) {
    return { use: "wait", seed: envelope.data };
  }
  return validateAgainstKnowledge(envelope.serverKnowledge, serverKnowledge) === "fresh"
    ? { use: "cache", value: envelope.data }
    : { use: "network", seed: envelope.data };
}

/**
 * Decide the bootstrap's accounts read, which is the one part of the reference
 * batch `server_knowledge` covers. Settings, categories and account
 * preferences are refetched whatever this returns.
 */
export function decideReferenceRefresh<T>(
  envelope: CacheEnvelope<T> | null,
  identity: CacheIdentity,
  serverKnowledge: number | null,
): "keep" | "refetch" {
  if (serverKnowledge === null) {
    return "refetch";
  }
  return planCachedFetch(envelope, identity, serverKnowledge).use === "cache" ? "keep" : "refetch";
}

// --- Storage shell -------------------------------------------------------
// Everything below touches `localStorage`. Storage may be unavailable or full
// (private browsing, quota), so every path is best-effort: a failure means the
// app fetches, which is exactly what it did before this cache existed.

/** Slots are separate keys so each carries the knowledge it was fetched at. */
export type CacheSlot = "reference" | "payees" | "scheduled" | "register";

/**
 * Counts how many times the cache has been invalidated in this tab.
 *
 * A read that started before a local write can resolve after it, carrying
 * pre-write rows. Writing those to a slot would repopulate a cache that had
 * just been emptied on purpose. Every fetch records the epoch it started at
 * and refuses to store its result if the epoch has moved since, so a write
 * cannot be overtaken by a read it already invalidated.
 */
let cacheEpoch = 0;

export function currentCacheEpoch(): number {
  return cacheEpoch;
}

const SLOTS: readonly CacheSlot[] = ["reference", "payees", "scheduled", "register"];

export function slotKey(slot: CacheSlot): string {
  return `${KEY_PREFIX}${slot}`;
}

export function readSlot<T>(
  slot: CacheSlot,
  guard: (value: unknown) => value is T,
): CacheEnvelope<T> | null {
  try {
    return deserialiseEnvelope(localStorage.getItem(slotKey(slot)), guard);
  } catch {
    return null;
  }
}

/**
 * Store a slot, unless the cache was invalidated while the read was in flight.
 *
 * `startedEpoch` is the value `currentCacheEpoch()` returned before the request
 * went out. If it no longer matches, a write happened in between and this
 * result predates it, so it is dropped rather than stored.
 */
export function writeSlot<T>(
  slot: CacheSlot,
  identity: CacheIdentity,
  serverKnowledge: number,
  data: T,
  startedEpoch?: number,
): void {
  if (startedEpoch !== undefined && startedEpoch !== cacheEpoch) {
    return;
  }
  try {
    localStorage.setItem(slotKey(slot), serialiseEnvelope(makeEnvelope(identity, serverKnowledge, data)));
  } catch {
    // Quota or private mode: caching is an optimisation, never a requirement.
  }
}

/**
 * Drop every cached slot. Called on sign-out, on a user or plan change, and
 * after any local write — a write returns the new knowledge but not, say, the
 * new account balances, so retagging an entry with it would mark stale data
 * fresh.
 */
export function clearReferenceCache(): void {
  // Bumped first, and outside the try: a read already in flight must be
  // refused its write even if the removals below cannot run.
  cacheEpoch += 1;
  try {
    for (const slot of SLOTS) {
      localStorage.removeItem(slotKey(slot));
    }
  } catch {
    // Nothing to clear if storage is unreachable.
  }
}
