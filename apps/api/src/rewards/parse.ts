import { ValidationError } from "../repository";
import { UNFLAGGED_FLAG, YNAB_FLAG_COLORS, type YnabFlagColor } from "./flags";
import type {
  AppSettings,
  CardRewardPeriod,
  CardSpendingTier,
  CardSubcategory,
  CreditCard,
  RewardGroupBy,
  SpendingTierSubcategory,
} from "./types";

const FLAG_COLOURS = new Set<string>([
  UNFLAGGED_FLAG.value,
  ...YNAB_FLAG_COLORS.map((flag) => flag.value),
]);

export function parseRewardGroupBy(value: string | null | undefined): RewardGroupBy {
  if (value === "payee" || value === "category" || value === "memo" || value === "flag") return value;
  return "flag";
}

export function parseAppSettings(value: unknown): AppSettings {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  const raw = value as Record<string, unknown>;
  const miles = typeof raw.milesValuation === "number" && Number.isFinite(raw.milesValuation)
    ? raw.milesValuation
    : undefined;
  return {
    currency: typeof raw.currency === "string" ? raw.currency : undefined,
    milesValuation: miles,
    dashboardViewMode: raw.dashboardViewMode === "detailed" ? "detailed" : "summary",
    groupCardsByType: raw.groupCardsByType === false ? false : true,
  };
}

export function parseCreditCards(value: unknown): CreditCard[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((entry) => {
    const card = parseCreditCard(entry);
    return card ? [card] : [];
  });
}

function parseCreditCard(value: unknown): CreditCard | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const raw = value as Record<string, unknown>;
  const id = stringValue(raw.id);
  const name = stringValue(raw.name);
  const accountId = stringValue(raw.ynabAccountId);
  if (!id || !name || !accountId) return null;
  const type = raw.type === "miles" ? "miles" : "cashback";
  return {
    ...(raw as CreditCard),
    id,
    name,
    issuer: stringValue(raw.issuer) ?? "",
    type,
    ynabAccountId: accountId,
    featured: raw.featured !== false,
  };
}

export function parseCreditCardWrite(value: unknown): CreditCard {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new ValidationError("Card must be a JSON object");
  }
  const raw = value as Record<string, unknown>;
  const id = stringValue(raw.id);
  const name = stringValue(raw.name);
  const accountId = stringValue(raw.ynabAccountId);
  if (!id) throw new ValidationError("Card id is required");
  if (!name) throw new ValidationError("Card name is required");
  if (!accountId) throw new ValidationError("Card ynabAccountId is required");
  if (raw.type != null && raw.type !== "cashback" && raw.type !== "miles") {
    throw new ValidationError("Card type must be cashback or miles");
  }

  const card: CreditCard = {
    id,
    name,
    issuer: stringValue(raw.issuer) ?? "",
    type: raw.type === "miles" ? "miles" : "cashback",
    ynabAccountId: accountId,
    featured: raw.featured !== false,
  };

  const billingCycle = parseBillingCycle(raw.billingCycle);
  if (billingCycle) card.billingCycle = billingCycle;
  const rewardPeriod = parseRewardPeriod(raw.rewardPeriod);
  if (rewardPeriod) card.rewardPeriod = rewardPeriod;
  const promotionalPeriod = parsePromotionalPeriod(raw.promotionalPeriod);
  if (promotionalPeriod) card.promotionalPeriod = promotionalPeriod;
  const earningRate = optionalFiniteNumber(raw.earningRate, "earningRate");
  if (earningRate !== undefined) card.earningRate = earningRate;
  const earningBlockSize = optionalFiniteNumber(raw.earningBlockSize, "earningBlockSize");
  if (earningBlockSize !== undefined) card.earningBlockSize = earningBlockSize;
  const minimumSpend = optionalFiniteNumber(raw.minimumSpend, "minimumSpend");
  if (minimumSpend !== undefined) card.minimumSpend = minimumSpend;
  const maximumSpend = optionalFiniteNumber(raw.maximumSpend, "maximumSpend");
  if (maximumSpend !== undefined) card.maximumSpend = maximumSpend;
  if (raw.subcategoriesEnabled !== undefined) card.subcategoriesEnabled = raw.subcategoriesEnabled === true;
  const subcategories = parseSubcategories(raw.subcategories);
  if (subcategories) card.subcategories = subcategories;
  const spendingTiers = parseSpendingTiers(raw.spendingTiers);
  if (spendingTiers) card.spendingTiers = spendingTiers;
  return card;
}

function parseBillingCycle(value: unknown): CreditCard["billingCycle"] | undefined {
  if (value == null) return undefined;
  if (typeof value !== "object" || Array.isArray(value)) {
    throw new ValidationError("billingCycle must be an object");
  }
  const raw = value as Record<string, unknown>;
  if (raw.type !== "calendar" && raw.type !== "billing") {
    throw new ValidationError("billingCycle type must be calendar or billing");
  }
  const cycle: NonNullable<CreditCard["billingCycle"]> = { type: raw.type };
  if (raw.dayOfMonth !== undefined) {
    if (typeof raw.dayOfMonth !== "number" || !Number.isFinite(raw.dayOfMonth)) {
      throw new ValidationError("billingCycle dayOfMonth must be a finite number");
    }
    cycle.dayOfMonth = raw.dayOfMonth;
  }
  return cycle;
}

function parseRewardPeriod(value: unknown): CardRewardPeriod | undefined {
  if (value == null) return undefined;
  if (typeof value !== "object" || Array.isArray(value)) {
    throw new ValidationError("rewardPeriod must be an object");
  }
  const raw = value as Record<string, unknown>;
  const monthCount = requiredFiniteNumber(raw.monthCount, "rewardPeriod.monthCount");
  const anchorDate = stringValue(raw.anchorDate);
  if (!anchorDate) throw new ValidationError("rewardPeriod.anchorDate is required");
  return {
    monthCount,
    anchorDate,
    monthlyMinimumSpend: requiredFiniteNumber(raw.monthlyMinimumSpend, "rewardPeriod.monthlyMinimumSpend"),
  };
}

function parsePromotionalPeriod(value: unknown): CreditCard["promotionalPeriod"] | undefined {
  if (value == null) return undefined;
  if (typeof value !== "object" || Array.isArray(value)) {
    throw new ValidationError("promotionalPeriod must be an object");
  }
  const raw = value as Record<string, unknown>;
  const endDate = stringValue(raw.endDate);
  if (!endDate) throw new ValidationError("promotionalPeriod.endDate is required");
  const period: NonNullable<CreditCard["promotionalPeriod"]> = { endDate };
  if (raw.startDate === null) period.startDate = null;
  else if (raw.startDate !== undefined) {
    const startDate = stringValue(raw.startDate);
    if (!startDate) throw new ValidationError("promotionalPeriod.startDate is invalid");
    period.startDate = startDate;
  }
  const description = stringValue(raw.description);
  if (description) period.description = description;
  return period;
}

function parseSubcategories(value: unknown): CardSubcategory[] | undefined {
  if (value == null) return undefined;
  if (!Array.isArray(value)) throw new ValidationError("subcategories must be an array");
  return value.map((entry, index) => parseSubcategory(entry, index));
}

function parseSubcategory(value: unknown, index: number): CardSubcategory {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new ValidationError(`subcategories[${index}] must be an object`);
  }
  const raw = value as Record<string, unknown>;
  const id = stringValue(raw.id);
  const name = stringValue(raw.name);
  if (!id || !name) throw new ValidationError(`subcategories[${index}] needs id and name`);
  const createdAt = stringValue(raw.createdAt);
  const updatedAt = stringValue(raw.updatedAt);
  if (!createdAt || !updatedAt) {
    throw new ValidationError(`subcategories[${index}] needs createdAt and updatedAt`);
  }
  const subcategory: CardSubcategory = {
    id,
    name,
    flagColor: parseFlagColour(raw.flagColor, `subcategories[${index}].flagColour`),
    rewardValue: requiredFiniteNumber(raw.rewardValue, `subcategories[${index}].rewardValue`),
    priority: requiredFiniteNumber(raw.priority, `subcategories[${index}].priority`),
    active: raw.active !== false,
    createdAt,
    updatedAt,
  };
  const milesBlockSize = optionalFiniteNumber(raw.milesBlockSize, `subcategories[${index}].milesBlockSize`);
  if (milesBlockSize !== undefined) subcategory.milesBlockSize = milesBlockSize;
  const minimumSpend = optionalFiniteNumber(raw.minimumSpend, `subcategories[${index}].minimumSpend`);
  if (minimumSpend !== undefined) subcategory.minimumSpend = minimumSpend;
  const maximumSpend = optionalFiniteNumber(raw.maximumSpend, `subcategories[${index}].maximumSpend`);
  if (maximumSpend !== undefined) subcategory.maximumSpend = maximumSpend;
  if (raw.excludeFromRewards !== undefined) subcategory.excludeFromRewards = raw.excludeFromRewards === true;
  return subcategory;
}

function parseSpendingTiers(value: unknown): CardSpendingTier[] | undefined {
  if (value == null) return undefined;
  if (!Array.isArray(value)) throw new ValidationError("spendingTiers must be an array");
  return value.map((entry, index) => parseSpendingTier(entry, index));
}

function parseSpendingTier(value: unknown, index: number): CardSpendingTier {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new ValidationError(`spendingTiers[${index}] must be an object`);
  }
  const raw = value as Record<string, unknown>;
  const id = stringValue(raw.id);
  if (!id) throw new ValidationError(`spendingTiers[${index}] needs id`);
  const tier: CardSpendingTier = {
    id,
    spendThreshold: requiredFiniteNumber(raw.spendThreshold, `spendingTiers[${index}].spendThreshold`),
  };
  const earningRate = optionalFiniteNumber(raw.earningRate, `spendingTiers[${index}].earningRate`);
  if (earningRate !== undefined) tier.earningRate = earningRate;
  const maximumSpend = optionalFiniteNumber(raw.maximumSpend, `spendingTiers[${index}].maximumSpend`);
  if (maximumSpend !== undefined) tier.maximumSpend = maximumSpend;
  if (raw.subcategories != null) {
    if (!Array.isArray(raw.subcategories)) {
      throw new ValidationError(`spendingTiers[${index}].subcategories must be an array`);
    }
    tier.subcategories = raw.subcategories.map((entry, subIndex) => {
      if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
        throw new ValidationError(`spendingTiers[${index}].subcategories[${subIndex}] must be an object`);
      }
      const nested = entry as Record<string, unknown>;
      const subcategoryId = stringValue(nested.subcategoryId);
      if (!subcategoryId) {
        throw new ValidationError(`spendingTiers[${index}].subcategories[${subIndex}] needs subcategoryId`);
      }
      const mapped: SpendingTierSubcategory = {
        subcategoryId,
        rewardValue: requiredFiniteNumber(nested.rewardValue, `spendingTiers[${index}].subcategories[${subIndex}].rewardValue`),
      };
      const nestedMaximum = optionalFiniteNumber(
        nested.maximumSpend,
        `spendingTiers[${index}].subcategories[${subIndex}].maximumSpend`,
      );
      if (nestedMaximum !== undefined) mapped.maximumSpend = nestedMaximum;
      return mapped;
    });
  }
  return tier;
}

function parseFlagColour(value: unknown, field: string): YnabFlagColor {
  if (typeof value !== "string" || !FLAG_COLOURS.has(value)) {
    throw new ValidationError(`${field} is not recognised`);
  }
  return value as YnabFlagColor;
}

function requiredFiniteNumber(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new ValidationError(`${field} must be a finite number`);
  }
  return value;
}

function optionalFiniteNumber(value: unknown, field: string): number | null | undefined {
  if (value === undefined) return undefined;
  if (value === null) return null;
  return requiredFiniteNumber(value, field);
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}
