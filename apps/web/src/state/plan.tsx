import { createContext, useCallback, useContext, useEffect, useRef, useState, type ReactNode } from "react";
import {
  ApiError,
  api,
  bumpRequestEpoch,
  setLocalWriteHandler,
  setUnauthorizedHandler,
  type ApiRequestOptions,
} from "../api/client";
import type {
  Account,
  AccountPreferences,
  AccountPreferencesSnapshot,
  Category,
  CategoryGroup,
  PlanSettings,
} from "../api/types";
import { configureMoney } from "../lib/money";
import { HalationMark } from "../components/Brand";
import {
  AccountPreferencesController,
  emptyAccountPreferences,
  type AccountPreferencesState,
} from "./account-preferences";
import {
  controllerKey as bootstrapControllerKey,
  decideBootstrap,
  decideSession,
  planBootstrapRequests,
  planKnowledge,
  resolveReferenceBatch,
  type Settled,
} from "./bootstrap";
import { isCachedReference, type CachedReference } from "./cache-shapes";
import { loadPrefs, savePrefs } from "./prefs";
import {
  clearReferenceCache,
  decideReferenceRefresh,
  readSlot,
  writeSlot,
  type CacheEnvelope,
} from "./reference-cache";

export interface PlanContextValue {
  planId: string;
  /** The signed-in user, so routes can key their own cache slots. */
  userId: string;
  /**
   * True while this value was painted from the client cache and the reads that
   * confirm it have not all landed. Nothing shown under it may be treated as
   * current; it clears only once settings, categories and accounts are either
   * refetched or validated against the plan's `server_knowledge`.
   */
  provisional: boolean;
  accounts: Account[];
  ledgerKnowledge: number;
  accountPreferences: AccountPreferences | null;
  accountPreferencesSync: AccountPreferencesState;
  updateAccountPreferences: (updater: (preferences: AccountPreferences) => AccountPreferences) => void;
  updateAccountIcon: (accountId: string, icon: string) => Promise<void>;
  retryAccountPreferences: () => void;
  categoryGroups: CategoryGroup[];
  categories: Category[];
  categoryNames: Map<string, string>;
  reload: () => void;
  logout: () => Promise<void>;
}

const PlanContext = createContext<PlanContextValue | null>(null);

export function usePlan(): PlanContextValue {
  const value = useContext(PlanContext);
  if (!value) {
    throw new Error("usePlan must be used within PlanProvider");
  }
  return value;
}

/** Flatten a promise so a decision can be made on its outcome either way. */
function settle<T>(promise: Promise<T>): Promise<Settled<T>> {
  return promise.then(
    (value) => ({ ok: true, value }) as Settled<T>,
    (error: unknown) => ({ ok: false, error }) as Settled<T>,
  );
}

interface ReferenceBatch {
  settings: PlanSettings;
  /** undefined when a cached copy is waiting on the knowledge check. */
  accounts: { accounts: Account[]; server_knowledge: number } | undefined;
  /** null means the server has no account preferences; undefined, not asked. */
  accountPreferences: AccountPreferencesSnapshot | null | undefined;
  categoryGroups: CategoryGroup[];
}

/** The four reads the shell needs before it can render a plan. */
async function fetchReferenceBatch(
  planId: string,
  withPreferences: boolean,
  withAccounts: boolean,
  options?: ApiRequestOptions,
): Promise<ReferenceBatch> {
  const [settings, accounts, accountPreferences, categoryGroups] = await Promise.all([
    api.settings(planId, options),
    withAccounts ? api.accounts(planId, options) : Promise.resolve(undefined),
    withPreferences ? api.accountPreferences(planId, options) : Promise.resolve(undefined),
    api.categories(planId, options),
  ]);
  return { settings, accounts, accountPreferences, categoryGroups };
}

/**
 * The first paint, straight from cache. It renders the shell before any
 * response arrives and is replaced the moment the real reads land.
 *
 * Account preferences sit in the `saving` phase throughout: the grouping is
 * shown, but the organisation dialog refuses edits until the real snapshot has
 * attached a controller with a revision worth sending back.
 */
function provisionalPlanValue(
  planId: string,
  envelope: CacheEnvelope<CachedReference>,
  actions: { reload: () => void; logout: () => Promise<void> },
): PlanContextValue {
  const { accounts, categoryGroups, accountPreferences } = envelope.data;
  const categories = categoryGroups.flatMap((group) => group.categories ?? []);
  const preferences = accountPreferences?.account_preferences ?? null;
  return {
    planId,
    userId: envelope.userId,
    provisional: true,
    accounts: accounts.filter((account) => !account.deleted),
    ledgerKnowledge: envelope.serverKnowledge,
    accountPreferences: preferences,
    accountPreferencesSync: {
      preferences: preferences ?? emptyAccountPreferences(),
      revision: accountPreferences?.account_preferences_revision ?? 0,
      phase: "saving",
      message: null,
    },
    updateAccountPreferences: () => {},
    updateAccountIcon: async () => {},
    retryAccountPreferences: () => {},
    categoryGroups,
    categories,
    categoryNames: new Map(categories.map((category) => [category.id, category.name])),
    reload: actions.reload,
    logout: actions.logout,
  };
}

export function PlanProvider({ children }: { children: ReactNode }) {
  const [value, setValue] = useState<PlanContextValue | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [authMode, setAuthMode] = useState<"checking" | "setup" | "login" | "ready">("checking");
  const [bootstrapRequired, setBootstrapRequired] = useState(true);
  const [generation, setGeneration] = useState(0);
  const accountPreferencesControllerRef = useRef<{
    key: string;
    planId: string;
    controller: AccountPreferencesController;
  } | null>(null);

  useEffect(() => {
    bumpRequestEpoch();
  }, [generation]);

  const reload = useCallback(() => setGeneration((number) => number + 1), []);

  const signOut = useCallback(async () => {
    await api.logout();
    accountPreferencesControllerRef.current?.controller.detach();
    accountPreferencesControllerRef.current = null;
    // The next person to sign in here should inherit neither this hint nor
    // any of this user's cached ledger data.
    savePrefs({ planId: undefined });
    clearReferenceCache();
    setValue(null);
    setError(null);
    setAuthMode("login");
  }, []);

  useEffect(() => {
    setUnauthorizedHandler(() => {
      accountPreferencesControllerRef.current?.controller.detach();
      accountPreferencesControllerRef.current = null;
      savePrefs({ planId: undefined });
      clearReferenceCache();
      setValue(null);
      setError("Your session ended. Sign in again.");
      setAuthMode("login");
    });
    // Every write already funnels through one place in the API client, so no
    // call site can leave a cached entry behind. A write returns the new
    // knowledge but not everything that number covers — a transaction moves
    // account balances the response does not carry — so the entry is dropped
    // rather than retagged with a number that would make it look current.
    setLocalWriteHandler(clearReferenceCache);
    return () => {
      setUnauthorizedHandler(null);
      setLocalWriteHandler(null);
    };
  }, []);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        // The session check, the plans list and - when a plan is remembered -
        // its reference data all start now, instead of one after another. The
        // pure helpers in ./bootstrap decide afterwards which answers survive.
        const attached = accountPreferencesControllerRef.current;
        const hint = loadPrefs().planId ?? null;
        // The cache is read before a single request is made, so the shell can
        // be on screen before the first response. Which user this browser is
        // signed in as is not known yet, so only the plan is matched here; the
        // session check below discards the paint if it belongs to someone else.
        const cached = hint && !attached
          ? readSlot<CachedReference>("reference", isCachedReference)
          : null;
        const paintedCache = cached?.planId === hint ? cached : null;
        if (paintedCache && hint && !cancelled) {
          configureMoney(paintedCache.data.settings.currency_format);
          setValue(provisionalPlanValue(hint, paintedCache, { reload, logout: signOut }));
        }
        const requests = planBootstrapRequests({
          hint,
          existingPlanId: attached?.planId ?? null,
          cachedPlanId: paintedCache?.planId ?? null,
        });
        // Only the calls that race ahead of the session check decide their own
        // 401s; once the session is known, a 401 means the session really has
        // ended and the global handler should see it.
        const speculative = { handleUnauthorized: false } as const;
        const statusPromise = api.authStatus();
        const plansPromise = settle(api.plans(speculative));
        const speculativePlanId = requests.speculativePlanId;
        const speculativeBatch = speculativePlanId
          ? settle(fetchReferenceBatch(
            speculativePlanId,
            requests.fetchPreferences,
            requests.fetchAccounts,
            speculative,
          ))
          : null;

        const status = await statusPromise;
        if (cancelled) return;
        setBootstrapRequired(status.bootstrap_required);
        const session = decideSession(status);
        if (session.kind === "signed-out") {
          // The sign-in form goes up now. Whatever the two speculative calls
          // return is never awaited, never read, and never reaches state. The
          // cache goes with it: nobody is signed in, so there is no session
          // against which any of it could be shown to belong to this browser.
          clearReferenceCache();
          setValue(null);
          setError(null);
          setAuthMode(session.mode);
          return;
        }
        setAuthMode("ready");
        const plansResult = await plansPromise;
        const batchResult = speculativeBatch ? await speculativeBatch : null;
        if (cancelled) return;
        if (!plansResult.ok) {
          throw plansResult.error;
        }
        const decision = decideBootstrap({
          status,
          plans: plansResult.value,
          speculativePlanId,
        });
        if (decision.kind !== "ready") {
          throw new Error("No plans are available yet.");
        }
        const planId = decision.planId;
        const identity = { userId: decision.userId, planId };
        // `GET /v1/plans` already carries the plan's `server_knowledge` and the
        // bootstrap already fetches it, so the knowledge check costs nothing.
        const knowledge = planKnowledge(plansResult.value, planId);
        // A cache belonging to another user, or to a plan this load is not
        // opening, is deleted rather than merely ignored.
        const validCache = paintedCache
          && paintedCache.userId === decision.userId
          && paintedCache.planId === planId
          ? paintedCache
          : null;
        if (paintedCache && !validCache) {
          clearReferenceCache();
          setValue(null);
        }
        const accountsDecision = decideReferenceRefresh(validCache, identity, knowledge);
        const controllerKey = bootstrapControllerKey(decision.userId, planId);
        const existingController = accountPreferencesControllerRef.current?.key === controllerKey
          ? accountPreferencesControllerRef.current.controller
          : null;
        const outcome = resolveReferenceBatch(decision, batchResult);
        if (outcome.kind === "fail") {
          throw outcome.error;
        }
        const batch = outcome.kind === "use"
          ? outcome.value
          : await fetchReferenceBatch(planId, !existingController, true);
        if (cancelled) {
          return;
        }
        const { settings, categoryGroups } = batch;
        // The accounts read is the one the cache can skip. When knowledge has
        // moved — or when the batch above went out for a different plan — it
        // is fetched now instead, one round trip later than a cold load.
        const accountsSnapshot = batch.accounts
          ?? (accountsDecision === "keep" && validCache
            ? { accounts: validCache.data.accounts, server_knowledge: validCache.serverKnowledge }
            : await api.accounts(planId));
        if (cancelled) {
          return;
        }
        // The batch skips preferences when a controller is already attached.
        // If that controller turns out to belong to another user or plan, ask
        // now rather than mistaking "not asked" for "server does not support".
        const accountPreferencesSnapshot = existingController
          ? null
          : batch.accountPreferences !== undefined
            ? batch.accountPreferences
            : await api.accountPreferences(planId);
        if (cancelled) {
          return;
        }
        configureMoney(settings.currency_format);
        savePrefs({ planId });
        // Tagged with the knowledge the accounts were actually read at, not
        // the plans list's, so a write landing between the two reads leaves
        // the entry looking advanced on the next load rather than current.
        writeSlot("reference", identity, accountsSnapshot.server_knowledge, {
          settings,
          categoryGroups,
          accounts: accountsSnapshot.accounts,
          // Preferences are not covered by knowledge and are not always
          // refetched, so an untouched controller keeps the cached copy.
          accountPreferences: accountPreferencesSnapshot ?? validCache?.data.accountPreferences ?? null,
        });
        const categories = categoryGroups.flatMap((group) => group.categories ?? []);
        let accountPreferencesSync: AccountPreferencesState;
        let accountPreferencesController = existingController;
        if (!accountPreferencesController && accountPreferencesSnapshot) {
          accountPreferencesControllerRef.current?.controller.detach();
          accountPreferencesController = new AccountPreferencesController(
            accountPreferencesSnapshot,
            {
              load: () => api.accountPreferences(planId),
              save: (preferences, expectedRevision) =>
                api.updateAccountPreferences(planId, preferences, expectedRevision),
            },
            (state) => {
              if (accountPreferencesControllerRef.current?.key !== controllerKey) return;
              setValue((current) => current?.planId === planId
                ? { ...current, accountPreferences: state.preferences, accountPreferencesSync: state }
                : current);
            },
          );
          accountPreferencesControllerRef.current = { key: controllerKey, planId, controller: accountPreferencesController };
        }
        if (accountPreferencesController) {
          accountPreferencesSync = accountPreferencesController.state;
        } else {
          accountPreferencesSync = {
            preferences: emptyAccountPreferences(),
            revision: 0,
            phase: "unsupported",
            message: "This server version does not support synced account organisation.",
          };
        }
        setValue({
          planId,
          userId: decision.userId,
          provisional: false,
          accounts: accountsSnapshot.accounts.filter((account) => !account.deleted),
          ledgerKnowledge: accountsSnapshot.server_knowledge,
          accountPreferences: accountPreferencesController ? accountPreferencesSync.preferences : null,
          accountPreferencesSync,
          updateAccountPreferences: (updater) => accountPreferencesController?.update(updater),
          updateAccountIcon: async (accountId, icon) => {
            setValue((current) => current?.planId === planId
              ? {
                  ...current,
                  accounts: current.accounts.map((account) =>
                    account.id === accountId ? { ...account, icon } : account),
                }
              : current);
            try {
              const updated = await api.updateAccountIcon(planId, accountId, icon);
              setValue((current) => current?.planId === planId
                ? {
                    ...current,
                    accounts: current.accounts.map((account) =>
                      account.id === updated.id ? updated : account),
                  }
                : current);
            } catch (cause) {
              setGeneration((n) => n + 1);
              throw cause;
            }
          },
          retryAccountPreferences: () => accountPreferencesController?.retry(),
          categoryGroups,
          categories,
          categoryNames: new Map(categories.map((category) => [category.id, category.name])),
          reload,
          logout: signOut,
        });
      } catch (cause) {
        if (!cancelled) {
          if (cause instanceof ApiError && cause.status === 401) {
            accountPreferencesControllerRef.current?.controller.detach();
            accountPreferencesControllerRef.current = null;
            savePrefs({ planId: undefined });
            setValue(null);
            setAuthMode("login");
          }
          setError(cause instanceof Error ? cause.message : String(cause));
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [generation]);

  useEffect(() => () => {
    accountPreferencesControllerRef.current?.controller.detach();
    accountPreferencesControllerRef.current = null;
  }, []);

  if (authMode === "setup" || authMode === "login") {
    return (
      <AuthForm
        mode={authMode}
        bootstrapRequired={bootstrapRequired}
        error={error}
        onSuccess={() => {
          setError(null);
          setAuthMode("checking");
          setGeneration((number) => number + 1);
        }}
        onError={setError}
      />
    );
  }

  if (error) {
    return (
      <div className="boot-message">
        <p>Could not reach HowMuch.</p>
        <p className="boot-detail">{error}</p>
        <button type="button" onClick={() => { setError(null); setGeneration((n) => n + 1); }}>
          Retry
        </button>
      </div>
    );
  }
  if (!value) {
    return <div className="boot-message">{authMode === "checking" ? "Checking session…" : "Loading…"}</div>;
  }
  return <PlanContext.Provider value={value}>{children}</PlanContext.Provider>;
}

function AuthForm({
  mode,
  bootstrapRequired,
  error,
  onSuccess,
  onError,
}: {
  mode: "setup" | "login";
  bootstrapRequired: boolean;
  error: string | null;
  onSuccess: () => void;
  onError: (message: string) => void;
}) {
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [bootstrapToken, setBootstrapToken] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const setup = mode === "setup";

  return (
    <form
      className="boot-message auth-form"
      onSubmit={async (event) => {
        event.preventDefault();
        setSubmitting(true);
        try {
          if (setup) await api.setup(username, password, bootstrapToken);
          else await api.login(username, password);
          setPassword("");
          setBootstrapToken("");
          onSuccess();
        } catch (cause) {
          onError(cause instanceof Error ? cause.message : String(cause));
        } finally {
          setSubmitting(false);
        }
      }}
    >
      <HalationMark size="hero" />
      <h1>{setup ? "Set up HowMuch" : "Sign in to HowMuch"}</h1>
      <p>{setup ? "Create your account." : "Enter your username and password."}</p>
      <label>
        <span>Username</span>
        <input
          type="text"
          value={username}
          onChange={(event) => setUsername(event.target.value)}
          autoComplete="username"
          pattern={"[A-Za-z0-9._\\-]{3,64}"}
          minLength={3}
          maxLength={64}
          autoCapitalize="none"
          autoFocus
          required
        />
      </label>
      <label>
        <span>Password</span>
        <input
          type="password"
          value={password}
          onChange={(event) => setPassword(event.target.value)}
          autoComplete={setup ? "new-password" : "current-password"}
          minLength={15}
          required
        />
      </label>
      {setup && bootstrapRequired && (
        <label>
          <span>Setup token</span>
          <input
            type="password"
            value={bootstrapToken}
            onChange={(event) => setBootstrapToken(event.target.value)}
            autoComplete="off"
            required
          />
        </label>
      )}
      <button
        type="submit"
        disabled={submitting || !username || password.length < 15 || (setup && bootstrapRequired && !bootstrapToken)}
      >
        {submitting ? "Please wait…" : setup ? "Create account" : "Sign in"}
      </button>
      {setup && bootstrapRequired && (
        <p className="boot-hint">This setup token is used once and is not stored in this browser.</p>
      )}
      {error && <p className="boot-detail" role="alert">{error}</p>}
    </form>
  );
}
