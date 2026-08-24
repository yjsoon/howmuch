import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from "react";
import { ApiError, api, bumpRequestEpoch, setUnauthorizedHandler } from "../api/client";
import type { Account, AccountPreferences, Category, CategoryGroup } from "../api/types";
import { configureMoney } from "../lib/money";
import {
  AccountPreferencesController,
  emptyAccountPreferences,
  type AccountPreferencesState,
} from "./account-preferences";

export interface PlanContextValue {
  planId: string;
  accounts: Account[];
  ledgerKnowledge: number;
  accountPreferences: AccountPreferences | null;
  accountPreferencesSync: AccountPreferencesState;
  updateAccountPreferences: (updater: (preferences: AccountPreferences) => AccountPreferences) => void;
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

export function PlanProvider({ children }: { children: ReactNode }) {
  const [value, setValue] = useState<PlanContextValue | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [authMode, setAuthMode] = useState<"checking" | "setup" | "login" | "ready">("checking");
  const [bootstrapRequired, setBootstrapRequired] = useState(true);
  const [generation, setGeneration] = useState(0);
  const accountPreferencesControllerRef = useRef<{
    key: string;
    controller: AccountPreferencesController;
  } | null>(null);

  useEffect(() => {
    bumpRequestEpoch();
  }, [generation]);

  useEffect(() => {
    setUnauthorizedHandler(() => {
      accountPreferencesControllerRef.current?.controller.detach();
      accountPreferencesControllerRef.current = null;
      setValue(null);
      setError("Your session ended. Sign in again.");
      setAuthMode("login");
    });
    return () => setUnauthorizedHandler(null);
  }, []);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const status = await api.authStatus();
        if (cancelled) return;
        setBootstrapRequired(status.bootstrap_required);
        if (!status.user) {
          setValue(null);
          setError(null);
          setAuthMode(status.setup_required ? "setup" : "login");
          return;
        }
        setAuthMode("ready");
        const plans = await api.plans();
        const planId = plans[0]?.id;
        if (!planId) {
          throw new Error("No plans found — run an import or create a transaction first.");
        }
        const controllerKey = `${status.user.id}:${planId}`;
        const existingController = accountPreferencesControllerRef.current?.key === controllerKey
          ? accountPreferencesControllerRef.current.controller
          : null;
        const [settings, accountsSnapshot, accountPreferencesSnapshot, categoryGroups] = await Promise.all([
          api.settings(planId),
          api.accounts(planId),
          existingController ? Promise.resolve(null) : api.accountPreferences(planId),
          api.categories(planId),
        ]);
        if (cancelled) {
          return;
        }
        configureMoney(settings.currency_format);
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
          accountPreferencesControllerRef.current = { key: controllerKey, controller: accountPreferencesController };
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
          accounts: accountsSnapshot.accounts.filter((account) => !account.deleted),
          ledgerKnowledge: accountsSnapshot.server_knowledge,
          accountPreferences: accountPreferencesController ? accountPreferencesSync.preferences : null,
          accountPreferencesSync,
          updateAccountPreferences: (updater) => accountPreferencesController?.update(updater),
          retryAccountPreferences: () => accountPreferencesController?.retry(),
          categoryGroups,
          categories,
          categoryNames: new Map(categories.map((category) => [category.id, category.name])),
          reload: () => setGeneration((n) => n + 1),
          logout: async () => {
            await api.logout();
            accountPreferencesControllerRef.current?.controller.detach();
            accountPreferencesControllerRef.current = null;
            setValue(null);
            setError(null);
            setAuthMode("login");
          },
        });
      } catch (cause) {
        if (!cancelled) {
          if (cause instanceof ApiError && cause.status === 401) {
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
        <p>Could not reach the HowMuch API.</p>
        <p className="boot-detail">{error}</p>
        <button type="button" onClick={() => { setError(null); setGeneration((n) => n + 1); }}>
          Retry
        </button>
      </div>
    );
  }
  if (!value) {
    return <div className="boot-message">{authMode === "checking" ? "Checking session…" : "Loading ledger…"}</div>;
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
      <h1>{setup ? "Set up HowMuch" : "Sign in to HowMuch"}</h1>
      <p>{setup ? "Create the first owner account." : "Enter your username and password."}</p>
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
          <span>Bootstrap token</span>
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
        <p className="boot-hint">The bootstrap token is used once and is never stored in this browser.</p>
      )}
      {error && <p className="boot-detail" role="alert">{error}</p>}
    </form>
  );
}
