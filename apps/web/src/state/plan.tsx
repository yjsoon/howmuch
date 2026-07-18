import { createContext, useContext, useEffect, useState, type ReactNode } from "react";
import { ApiError, api, setApiToken } from "../api/client";
import type { Account, Category, CategoryGroup } from "../api/types";
import { configureMoney } from "../lib/money";

export interface PlanContextValue {
  planId: string;
  accounts: Account[];
  categoryGroups: CategoryGroup[];
  categories: Category[];
  categoryNames: Map<string, string>;
  reload: () => void;
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
  const [authRequired, setAuthRequired] = useState(false);
  const [token, setToken] = useState("");
  const [generation, setGeneration] = useState(0);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const plans = await api.plans();
        const planId = plans[0]?.id;
        if (!planId) {
          throw new Error("No plans found — run an import or create a transaction first.");
        }
        const [settings, accounts, categoryGroups] = await Promise.all([
          api.settings(planId),
          api.accounts(planId),
          api.categories(planId),
        ]);
        if (cancelled) {
          return;
        }
        configureMoney(settings.currency_format);
        const categories = categoryGroups.flatMap((group) => group.categories ?? []);
        setValue({
          planId,
          accounts: accounts.filter((account) => !account.deleted),
          categoryGroups,
          categories,
          categoryNames: new Map(categories.map((category) => [category.id, category.name])),
          reload: () => setGeneration((n) => n + 1),
        });
      } catch (cause) {
        if (!cancelled) {
          setAuthRequired(cause instanceof ApiError && cause.status === 401);
          setError(cause instanceof Error ? cause.message : String(cause));
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [generation]);

  if (error) {
    if (authRequired) {
      return (
        <form
          className="boot-message auth-form"
          onSubmit={(event) => {
            event.preventDefault();
            setApiToken(token);
            setAuthRequired(false);
            setError(null);
            setGeneration((n) => n + 1);
          }}
        >
          <h1>Unlock HowMuch</h1>
          <p>Enter the bearer token for this deployment.</p>
          <input
            type="password"
            value={token}
            onChange={(event) => setToken(event.target.value)}
            autoComplete="current-password"
            aria-label="Bearer token"
            autoFocus
          />
          <button type="submit" disabled={!token.trim()}>Unlock</button>
          <p className="boot-detail">The token is kept in this tab only.</p>
        </form>
      );
    }
    return (
      <div className="boot-message">
        <p>Could not reach the HowMuch API.</p>
        <p className="boot-detail">{error}</p>
        <button type="button" onClick={() => { setAuthRequired(false); setError(null); setGeneration((n) => n + 1); }}>
          Retry
        </button>
      </div>
    );
  }
  if (!value) {
    return <div className="boot-message">Loading ledger…</div>;
  }
  return <PlanContext.Provider value={value}>{children}</PlanContext.Provider>;
}
