import { describe, expect, test } from "bun:test";
import {
  choosePlanId,
  decideSession,
  controllerKey,
  decideBootstrap,
  planBootstrapRequests,
  resolveReferenceBatch,
} from "./bootstrap";

const signedIn = { user: { id: "user-1" }, setup_required: false, bootstrap_required: false };

describe("planBootstrapRequests", () => {
  test("prefers the attached controller's plan and skips preferences", () => {
    expect(planBootstrapRequests({ hint: "plan-b", existingPlanId: "plan-a" })).toEqual({
      speculativePlanId: "plan-a",
      fetchPreferences: false,
    });
  });

  test("uses the remembered plan on a cold load", () => {
    expect(planBootstrapRequests({ hint: "plan-b", existingPlanId: null })).toEqual({
      speculativePlanId: "plan-b",
      fetchPreferences: true,
    });
  });

  test("waits for the plans list when nothing is remembered", () => {
    expect(planBootstrapRequests({ hint: null, existingPlanId: null })).toEqual({
      speculativePlanId: null,
      fetchPreferences: true,
    });
  });
});

describe("choosePlanId", () => {
  test("keeps the hint when it is still readable", () => {
    expect(choosePlanId([{ id: "plan-a" }, { id: "plan-b" }], "plan-b")).toBe("plan-b");
  });

  test("falls back to the first plan when the hint is gone", () => {
    expect(choosePlanId([{ id: "plan-a" }], "plan-b")).toBe("plan-a");
  });

  test("returns null when no plan is readable", () => {
    expect(choosePlanId([], "plan-b")).toBeNull();
  });
});

describe("decideSession", () => {
  test("reads the session without consulting anything else", () => {
    expect(decideSession(signedIn)).toEqual({ kind: "signed-in", userId: "user-1" });
    expect(decideSession({ user: null, setup_required: false, bootstrap_required: false }))
      .toEqual({ kind: "signed-out", mode: "login" });
    expect(decideSession({ user: null, setup_required: true, bootstrap_required: true }))
      .toEqual({ kind: "signed-out", mode: "setup" });
  });
});

describe("decideBootstrap", () => {
  test("keeps the speculative batch when the hint is confirmed", () => {
    expect(decideBootstrap({
      status: signedIn,
      plans: [{ id: "plan-a" }, { id: "plan-b" }],
      speculativePlanId: "plan-b",
    })).toEqual({ kind: "ready", userId: "user-1", planId: "plan-b", keepSpeculative: true });
  });

  test("falls back to the first plan and discards the batch when the hint is stale", () => {
    expect(decideBootstrap({
      status: signedIn,
      plans: [{ id: "plan-a" }],
      speculativePlanId: "plan-gone",
    })).toEqual({ kind: "ready", userId: "user-1", planId: "plan-a", keepSpeculative: false });
  });

  test("never keeps a batch that was not started", () => {
    expect(decideBootstrap({
      status: signedIn,
      plans: [{ id: "plan-a" }],
      speculativePlanId: null,
    })).toEqual({ kind: "ready", userId: "user-1", planId: "plan-a", keepSpeculative: false });
  });

  test("reports when the account has no readable plan", () => {
    expect(decideBootstrap({ status: signedIn, plans: [], speculativePlanId: null }))
      .toEqual({ kind: "no-plans" });
  });

  test("an invalid session yields no plan state even when plans and a batch arrived", () => {
    const decision = decideBootstrap({
      status: { user: null, setup_required: false, bootstrap_required: true },
      plans: [{ id: "plan-a" }, { id: "plan-b" }],
      speculativePlanId: "plan-b",
    });
    expect(decision).toEqual({ kind: "signed-out", mode: "login" });
    expect(decision).not.toHaveProperty("planId");
    expect(resolveReferenceBatch({ keepSpeculative: false }, { ok: true, value: "reference data" }))
      .toEqual({ kind: "refetch" });
  });

  test("an unclaimed server asks for setup rather than sign-in", () => {
    expect(decideBootstrap({
      status: { user: null, setup_required: true, bootstrap_required: true },
      plans: [],
      speculativePlanId: null,
    })).toEqual({ kind: "signed-out", mode: "setup" });
  });
});

describe("resolveReferenceBatch", () => {
  test("uses a batch fetched for the chosen plan", () => {
    expect(resolveReferenceBatch({ keepSpeculative: true }, { ok: true, value: 42 }))
      .toEqual({ kind: "use", value: 42 });
  });

  test("surfaces the failure of a batch for the chosen plan", () => {
    const error = new Error("categories unavailable");
    expect(resolveReferenceBatch({ keepSpeculative: true }, { ok: false, error }))
      .toEqual({ kind: "fail", error });
  });

  test("discards a batch fetched for a plan that was not chosen", () => {
    expect(resolveReferenceBatch({ keepSpeculative: false }, { ok: false, error: new Error("404") }))
      .toEqual({ kind: "refetch" });
    expect(resolveReferenceBatch({ keepSpeculative: true }, null)).toEqual({ kind: "refetch" });
  });
});

describe("controllerKey", () => {
  test("scopes a controller to one user and plan", () => {
    expect(controllerKey("user-1", "plan-a")).toBe("user-1:plan-a");
    expect(controllerKey("user-1", "plan-a")).not.toBe(controllerKey("user-2", "plan-a"));
  });
});
