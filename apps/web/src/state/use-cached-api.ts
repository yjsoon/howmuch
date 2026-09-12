/**
 * The effect wiring for a validated cache slot. Every decision it makes comes
 * from `./reference-cache`; this file only runs them.
 *
 * Three outcomes, and the first is the whole point of #175:
 *
 * - Cached knowledge equals the plan's current `server_knowledge`, so the
 *   entry is provably current and no request is made at all.
 * - The plan's knowledge is not known yet but an entry exists: paint it, mark
 *   it provisional, and wait for the check rather than fetching blind.
 * - Anything else: fetch, showing the entry as a seed if there is one until
 *   the response replaces it.
 */

import { useEffect, useRef, useState } from "react";
import type { ApiState } from "../api/client";
import {
  currentCacheEpoch,
  planCachedFetch,
  readSlot,
  writeSlot,
  type CacheIdentity,
  type CacheSlot,
} from "./reference-cache";

export interface CachedApiState<T> extends ApiState<T> {
  /** True while the rendered data came from cache and a fetch is still out. */
  provisional: boolean;
}

export interface CachedApiOptions<T> {
  slot: CacheSlot;
  /** Identity of the loaded state, as `useApi`'s key. Refetches when it changes. */
  key: string;
  identity: CacheIdentity | null;
  /** The plan's current knowledge, or null when it is not known yet. */
  serverKnowledge: number | null;
  guard: (value: unknown) => value is T;
  fetcher: () => Promise<T>;
  /**
   * The cache epoch this route last saw. Passing it makes a local write re-run
   * the read: the slot has just been emptied, so the branch that would have
   * skipped the request on a knowledge match now goes to the network instead.
   */
  cacheEpoch: number;
}

interface InternalState<T> extends CachedApiState<T> {
  key: string;
}

export function useCachedApi<T>(options: CachedApiOptions<T>): CachedApiState<T> {
  const { slot, key, identity, serverKnowledge, guard, cacheEpoch } = options;
  const [state, setState] = useState<InternalState<T>>({
    data: null,
    loading: true,
    error: null,
    provisional: false,
    key,
  });
  const optionsRef = useRef(options);
  optionsRef.current = options;

  // `identity` is rebuilt on every render, so the effect keys on its parts.
  const userId = identity?.userId ?? null;
  const planId = identity?.planId ?? null;

  useEffect(() => {
    let cancelled = false;
    const current = optionsRef.current;
    const resolved = userId && planId ? { userId, planId } : null;
    const decision = resolved
      ? planCachedFetch(readSlot<T>(slot, guard), resolved, serverKnowledge)
      : ({ use: "network", seed: null } as const);

    if (decision.use === "cache") {
      setState({ data: decision.value, loading: false, error: null, provisional: false, key });
      return;
    }

    if (decision.use === "wait") {
      // The knowledge check is one response away and already in flight. Paint
      // the entry, say it is provisional, and let the next run decide.
      setState({ data: decision.seed, loading: true, error: null, provisional: true, key });
      return;
    }

    setState({
      data: decision.seed,
      loading: true,
      error: null,
      provisional: decision.seed !== null,
      key,
    });
    // Recorded before the request goes out. If a local write empties the cache
    // while this is in flight, the result predates that write and `writeSlot`
    // refuses to store it, so an invalidated slot cannot be refilled with rows
    // the write has already superseded.
    const startedEpoch = currentCacheEpoch();
    current
      .fetcher()
      .then((data) => {
        if (cancelled) return;
        if (resolved && serverKnowledge !== null) {
          writeSlot(slot, resolved, serverKnowledge, data, startedEpoch);
        }
        setState({ data, loading: false, error: null, provisional: false, key });
      })
      .catch((error: Error) => {
        if (cancelled) return;
        // A failed refresh must not leave the seed on screen pretending to be
        // current, so the seed goes with it.
        setState({ data: null, loading: false, error: error.message, provisional: false, key });
      });
    return () => {
      cancelled = true;
    };
  }, [slot, key, userId, planId, serverKnowledge, guard, cacheEpoch]);

  const matched = state.key === key;
  return {
    data: matched ? state.data : null,
    loading: matched ? state.loading : true,
    error: matched ? state.error : null,
    provisional: matched && state.provisional,
  };
}
