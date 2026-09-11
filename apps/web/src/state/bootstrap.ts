/**
 * Pure decision logic for the first paint of the app.
 *
 * `PlanProvider` fires the session check, the plans list and — when a plan is
 * remembered — the reference batch all at once. Because those requests race,
 * something has to decide afterwards which answers may be used and which must
 * be thrown away. That decision lives here, with no fetching and no state, so
 * the "discard" branches can be tested directly.
 */

export interface BootstrapSessionStatus {
  user: { id: string } | null;
  setup_required: boolean;
  bootstrap_required: boolean;
}

export interface PlanRef {
  id: string;
  /** The plan's current `server_knowledge`, when the server reports it. */
  server_knowledge?: number;
}

/** A promise outcome, flattened so decisions can be made on plain values. */
export type Settled<T> =
  | { ok: true; value: T }
  | { ok: false; error: unknown };

/** Which requests the provider should start before anything has resolved. */
export interface BootstrapRequestPlan {
  /** Plan to fetch reference data for up front, or null to wait for the list. */
  speculativePlanId: string | null;
  /** Account preferences are only refetched when no controller is attached. */
  fetchPreferences: boolean;
  /**
   * Accounts are the one part of the batch `server_knowledge` validates, so a
   * cached copy for this plan holds the request back until the plans list has
   * said whether knowledge moved. Settings, categories and preferences are
   * fetched regardless: no write to them bumps knowledge.
   */
  fetchAccounts: boolean;
}

export type SessionDecision =
  | { kind: "signed-out"; mode: "setup" | "login" }
  | { kind: "signed-in"; userId: string };

export type BootstrapDecision =
  | { kind: "signed-out"; mode: "setup" | "login" }
  | { kind: "no-plans" }
  | { kind: "ready"; userId: string; planId: string; keepSpeculative: boolean };

/**
 * Decide what to request before the session is known. On a reload the attached
 * controller's plan is authoritative, so it beats the remembered hint.
 */
export function planBootstrapRequests(
  input: { hint: string | null; existingPlanId: string | null; cachedPlanId?: string | null },
): BootstrapRequestPlan {
  const existingPlanId = input.existingPlanId;
  const speculativePlanId = existingPlanId ?? input.hint ?? null;
  const cachedPlanId = input.cachedPlanId ?? null;
  return {
    speculativePlanId,
    fetchPreferences: !existingPlanId,
    fetchAccounts: speculativePlanId === null || cachedPlanId !== speculativePlanId,
  };
}

/** The remembered plan if it is still readable, else the first one listed. */
export function choosePlanId(plans: readonly PlanRef[], hint: string | null): string | null {
  if (hint && plans.some((plan) => plan.id === hint)) {
    return hint;
  }
  return plans[0]?.id ?? null;
}

/**
 * Read the session, and nothing else. The provider calls this the moment the
 * status arrives so the sign-in form can appear without waiting for requests
 * whose answers it is about to throw away.
 */
export function decideSession(status: BootstrapSessionStatus): SessionDecision {
  return status.user
    ? { kind: "signed-in", userId: status.user.id }
    : { kind: "signed-out", mode: status.setup_required ? "setup" : "login" };
}

/**
 * Resolve the bootstrap race.
 *
 * The session is decided from `status` alone and returns before `plans` is
 * read at all: nothing fetched alongside an invalid session can reach the
 * caller, however far ahead of the session check it finished.
 */
export function decideBootstrap(input: {
  status: BootstrapSessionStatus;
  plans: readonly PlanRef[];
  speculativePlanId: string | null;
}): BootstrapDecision {
  const session = decideSession(input.status);
  if (session.kind === "signed-out") {
    return session;
  }
  const planId = choosePlanId(input.plans, input.speculativePlanId);
  if (!planId) {
    return { kind: "no-plans" };
  }
  return {
    kind: "ready",
    userId: session.userId,
    planId,
    keepSpeculative: input.speculativePlanId !== null && planId === input.speculativePlanId,
  };
}

export type ReferenceBatchOutcome<T> =
  | { kind: "use"; value: T }
  | { kind: "refetch" }
  | { kind: "fail"; error: unknown };

/**
 * What to do with a speculative reference batch once the plan is settled.
 *
 * A batch fetched for a plan we are not using is discarded silently. A batch
 * fetched for the plan we did choose is the real one, so its failure is the
 * bootstrap's failure — refetching it would only repeat the error.
 */
export function resolveReferenceBatch<T>(
  decision: { keepSpeculative: boolean },
  batch: Settled<T> | null,
): ReferenceBatchOutcome<T> {
  if (!decision.keepSpeculative || !batch) {
    return { kind: "refetch" };
  }
  return batch.ok ? { kind: "use", value: batch.value } : { kind: "fail", error: batch.error };
}

/**
 * The plan's knowledge as the plans list reports it, or null when this server
 * does not report one. Null means the cache cannot be validated, so it is not
 * used — the plans list is the whole knowledge check.
 */
export function planKnowledge(plans: readonly PlanRef[], planId: string): number | null {
  const knowledge = plans.find((plan) => plan.id === planId)?.server_knowledge;
  return typeof knowledge === "number" && Number.isFinite(knowledge) ? knowledge : null;
}

/** Key identifying the account-preferences controller for a user and plan. */
export function controllerKey(userId: string, planId: string): string {
  return `${userId}:${planId}`;
}
