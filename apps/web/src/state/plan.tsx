import { createContext, useContext, useEffect, useState, type ReactNode } from "react";
import { api } from "../api/client";
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
          setError(cause instanceof Error ? cause.message : String(cause));
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [generation]);

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
    return <div className="boot-message">Loading ledger…</div>;
  }
  return <PlanContext.Provider value={value}>{children}</PlanContext.Provider>;
}
