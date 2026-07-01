import { createContext, useContext, useEffect, useState, type ReactNode } from "react";
import { api, ApiError, getApiToken, setApiToken } from "../api/client";
import type { Account, Category, CategoryGroup } from "../api/types";
import { configureMoney } from "../lib/money";
import { Onboarding } from "../components/Onboarding";

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

type BootState =
  | { kind: "loading" }
  | { kind: "ready"; value: PlanContextValue }
  | { kind: "empty"; defaultPlanId: string }
  | { kind: "unauthorised" }
  | { kind: "error"; message: string };

export function PlanProvider({ children }: { children: ReactNode }) {
  const [state, setState] = useState<BootState>({ kind: "loading" });
  const [generation, setGeneration] = useState(0);
  const reload = () => setGeneration((n) => n + 1);

  useEffect(() => {
    let cancelled = false;
    setState({ kind: "loading" });
    (async () => {
      try {
        const plans = await api.plans();
        const planId = plans[0]?.id;
        if (!planId) {
          const bootstrap = await fetch("/api/bootstrap", {
            headers: getApiToken() ? { authorization: `Bearer ${getApiToken()}` } : {},
          }).then((response) => response.json());
          if (!cancelled) {
            setState({ kind: "empty", defaultPlanId: bootstrap?.data?.default_plan_id ?? "howmuch" });
          }
          return;
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
        setState({
          kind: "ready",
          value: {
            planId,
            accounts: accounts.filter((account) => !account.deleted),
            categoryGroups,
            categories,
            categoryNames: new Map(categories.map((category) => [category.id, category.name])),
            reload,
          },
        });
      } catch (cause) {
        if (cancelled) {
          return;
        }
        if (cause instanceof ApiError && cause.status === 401) {
          setState({ kind: "unauthorised" });
        } else {
          setState({ kind: "error", message: cause instanceof Error ? cause.message : String(cause) });
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [generation]);

  if (state.kind === "loading") {
    return <div className="boot-message">Loading ledger…</div>;
  }
  if (state.kind === "unauthorised") {
    return <TokenGate onSaved={reload} />;
  }
  if (state.kind === "empty") {
    return <Onboarding defaultPlanId={state.defaultPlanId} onReady={reload} />;
  }
  if (state.kind === "error") {
    return (
      <div className="boot-message">
        <p>Could not reach the HowMuch API.</p>
        <p className="boot-detail">{state.message}</p>
        <button type="button" onClick={reload}>
          Retry
        </button>
      </div>
    );
  }
  return <PlanContext.Provider value={state.value}>{children}</PlanContext.Provider>;
}

function TokenGate({ onSaved }: { onSaved: () => void }) {
  const [token, setToken] = useState(getApiToken() ?? "");
  return (
    <div className="boot-message">
      <p>This HowMuch server requires an API token.</p>
      <p className="boot-detail">
        Enter the value of <code>HOWMUCH_API_TOKEN</code> configured on the server. It is stored only in this
        browser.
      </p>
      <form
        className="token-form"
        onSubmit={(event) => {
          event.preventDefault();
          setApiToken(token.trim() || null);
          onSaved();
        }}
      >
        <input
          type="password"
          value={token}
          onChange={(event) => setToken(event.target.value)}
          placeholder="API token"
          aria-label="API token"
          autoFocus
        />
        <button type="submit">Unlock</button>
      </form>
    </div>
  );
}
