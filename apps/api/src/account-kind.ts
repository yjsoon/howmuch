/** The account types HowMuch classifies. Single source for on_budget and the default icon. */
export const ACCOUNT_KINDS = {
  checking: { onBudget: true, defaultIcon: "🏦" },
  savings: { onBudget: true, defaultIcon: "💰" },
  cash: { onBudget: true, defaultIcon: "💵" },
  creditCard: { onBudget: true, defaultIcon: "💳" },
  lineOfCredit: { onBudget: true, defaultIcon: "💳" },
  mortgage: { onBudget: false, defaultIcon: "🏠" },
  autoLoan: { onBudget: false, defaultIcon: "🚗" },
  studentLoan: { onBudget: false, defaultIcon: "🎓" },
  medicalDebt: { onBudget: false, defaultIcon: "🏥" },
  otherLoan: { onBudget: false, defaultIcon: "📄" },
  otherAsset: { onBudget: false, defaultIcon: "📈" },
  otherLiability: { onBudget: false, defaultIcon: "📉" },
} as const satisfies Record<string, { onBudget: boolean; defaultIcon: string }>;

export type AccountKind = keyof typeof ACCOUNT_KINDS;

export type AccountUpdatePatch = {
  icon?: string;
  name?: string;
  kind?: AccountKind;
};

export type AccountUpdateExisting = {
  name: string;
  icon?: string | null;
  type?: string | null;
};

/** Boundary parse. Imported strings outside the table are not writable. */
export function parseAccountKind(value: unknown): AccountKind | null {
  return typeof value === "string" && Object.prototype.hasOwnProperty.call(ACCOUNT_KINDS, value)
    ? value as AccountKind
    : null;
}

export function onBudgetForKind(kind: AccountKind): boolean {
  return ACCOUNT_KINDS[kind].onBudget;
}

/** Identity merge for PATCH. Balances are never in the result. */
export function applyAccountUpdate(
  existing: AccountUpdateExisting,
  patch: AccountUpdatePatch,
): { name?: string; icon?: string; type?: AccountKind; on_budget?: boolean } {
  const next: { name?: string; icon?: string; type?: AccountKind; on_budget?: boolean } = {};
  if (patch.name !== undefined) {
    next.name = patch.name.trim();
  }
  if (patch.kind !== undefined) {
    next.type = patch.kind;
    next.on_budget = onBudgetForKind(patch.kind);
    if (patch.icon === undefined) {
      const stored = existing.icon == null || existing.icon === "" ? null : existing.icon;
      const previousDefault = existing.type && Object.prototype.hasOwnProperty.call(ACCOUNT_KINDS, existing.type)
        ? ACCOUNT_KINDS[existing.type as AccountKind].defaultIcon
        : "🏦";
      if (stored == null || stored === previousDefault) {
        next.icon = ACCOUNT_KINDS[patch.kind].defaultIcon;
      }
    }
  }
  if (patch.icon !== undefined) {
    next.icon = patch.icon;
  }
  return next;
}
