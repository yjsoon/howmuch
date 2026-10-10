import { SimpleRewardsCalculator, type CalculationPeriod, type SimplifiedCalculation } from "./engine/simple-calculator";
import { resolveCardSpendingTier } from "./engine/utils/spending-tiers";
import { parseYnabDate, rewardsToday } from "./engine/date-utils";
import { ValidationError } from "../repository";
import type {
  AppSettings,
  CreditCard,
  RewardGroupBy,
  RewardGroupRow,
  RewardsCardCalculation,
  RewardsCardRow,
  RewardsReport,
  Transaction,
} from "./types";

const MILLIUNITS_PER_UNIT = 1000;

export function buildRewardsReport(input: {
  cards: CreditCard[];
  accountNames: Record<string, string>;
  transactions: Transaction[];
  settings: AppSettings;
  from: string | null;
  to: string | null;
  /** Historical attribution without `from`: the range starts at the earliest transaction. */
  range?: boolean;
  groupBy: RewardGroupBy;
  accountIds: string[];
}): RewardsReport {
  for (const field of ["from", "to"] as const) {
    const value = input[field];
    if (value !== null && !isCalendarDate(value)) {
      throw new ValidationError(`${field} must be a valid YYYY-MM-DD date`);
    }
  }
  if (input.from && input.to && input.from > input.to) {
    throw new ValidationError("from must not follow to");
  }
  const selected = new Set(input.accountIds);
  const cards = input.cards.filter((card) => {
    if (selected.size === 0) return true;
    return selected.has(card.ynabAccountId);
  });
  const today = rewardsToday();
  const asOf = input.to && input.to < today ? input.to : today;
  const from = input.from ?? (input.range
    ? input.transactions.reduce((earliest, t) => t.date < earliest ? t.date : earliest, asOf)
    : null);
  const inRange = new Map<string, Transaction>();
  const rewardByTransaction = new Map<string, { reward: number; rewardDollars: number }>();
  const cardRows: RewardsCardRow[] = cards.map((card) => {
    validatePeriodConfiguration(card);
    const history = input.transactions.filter((t) => t.account_id === card.ynabAccountId && t.date <= asOf);
    const current = cardPeriod(card, asOf, asOf);
    const selectedTransactions = history.filter((t) => t.date >= (from ?? current.start));
    const periods = new Map<string, CalculationPeriod>([[periodKey(current), current]]);
    const assigned = new Map<string, Transaction[]>();
    for (const transaction of selectedTransactions) {
      const period = from ? cardPeriod(card, transaction.date, asOf) : current;
      const key = periodKey(period);
      periods.set(key, period);
      const bucket = assigned.get(key) ?? [];
      bucket.push(transaction);
      assigned.set(key, bucket);
      inRange.set(transaction.id, transaction);
    }
    const results = [...periods.values()].sort((a, b) => a.start.localeCompare(b.start) || a.end.localeCompare(b.end)).map((period) => {
      const periodHistory = history.filter((transaction) => transaction.date >= period.start && transaction.date <= period.end);
      const calculation = SimpleRewardsCalculator.calculateCardRewards(card, periodHistory, period, input.settings);
      const transactions = assigned.get(periodKey(period)) ?? [];
      for (const transaction of transactions) {
        const result = calculation.transactionRewards[transaction.id];
        rewardByTransaction.set(transaction.id, { reward: result?.reward ?? 0, rewardDollars: result?.rewardDollars ?? 0 });
      }
      const full = serializeCalculation(card, calculation);
      return {
        period,
        full,
        attributed: from ? attributeCalculation(card, periodHistory, transactions, period, calculation, input.settings) : full,
      };
    });
    const latest = results.find((result) => periodKey(result.period) === periodKey(current))!;
    const calculation = { ...latest.full };
    for (const field of ["total_spend", "counted_spend", "eligible_spend", "reward_earned", "reward_earned_dollars"] as const) {
      calculation[field] = results.reduce((sum, result) => sum + result.attributed[field], 0);
    }
    const flags = new Map<string, RewardsCardCalculation["flags"][number]>();
    for (const result of results) {
      for (const flag of result.attributed.flags) {
        const previous = flags.get(flag.subcategoryId);
        const combined = { ...flag };
        if (previous) {
          for (const field of ["totalSpend", "countedSpend", "eligibleSpend", "eligibleSpendBeforeBlocks", "rewardEarned", "rewardEarnedDollars", "blocksEarned"] as const) {
            combined[field] = (previous[field] ?? 0) + (flag[field] ?? 0);
          }
        }
        flags.set(flag.subcategoryId, combined);
      }
    }
    return {
      card,
      account_id: card.ynabAccountId,
      account_name: input.accountNames[card.ynabAccountId] ?? card.name,
      calculation: {
        ...calculation,
        period: from ? `${from}:${asOf}` : current.label,
        flags: [...flags.values()],
        periods: results.map(({ period, full }) => ({ start: period.start, end: period.end, calculation: full })),
      },
    };
  });

  const groups = groupTransactions([...inRange.values()], input.groupBy, rewardByTransaction);

  return {
    from: input.from,
    to: input.to,
    as_of: asOf,
    period: from ? `${from}:${asOf}` : `Current card periods as of ${asOf}`,
    transaction_rewards: Object.fromEntries([...rewardByTransaction].map(([id, result]) => [id, { reward: result.reward, reward_dollars: result.rewardDollars }])),
    group_by: input.groupBy,
    miles_valuation: input.settings.milesValuation ?? 0.01,
    totals: {
      spend: cardRows.reduce((sum, row) => sum + row.calculation.total_spend, 0),
      reward_dollars: cardRows.reduce((sum, row) => sum + row.calculation.reward_earned_dollars, 0),
      cashback: cardRows
        .filter((row) => row.calculation.reward_type === "cashback")
        .reduce((sum, row) => sum + row.calculation.reward_earned, 0),
      miles: cardRows
        .filter((row) => row.calculation.reward_type === "miles")
        .reduce((sum, row) => sum + row.calculation.reward_earned, 0),
    },
    cards: cardRows,
    groups,
  };
}

function cardPeriod(card: CreditCard, date: string, asOf: string): CalculationPeriod {
  const period = SimpleRewardsCalculator.calculatePeriod(card, parseYnabDate(date));
  const anchor = card.rewardPeriod?.anchorDate;
  if (anchor && date < anchor && period.end >= anchor) {
    // The anchored regime replaces the previous calendar/billing/promotion
    // window on its start date; later spend must not requalify that old window.
    const previousDay = new Date(`${anchor}T00:00:00Z`);
    previousDay.setUTCDate(previousDay.getUTCDate() - 1);
    period.end = previousDay.toISOString().slice(0, 10);
  }
  return { ...period, asOf: period.end < asOf ? period.end : asOf };
}

function periodKey(period: CalculationPeriod): string {
  return `${period.start}:${period.end}`;
}

function isCalendarDate(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const parsed = new Date(`${value}T00:00:00Z`);
  return Number.isFinite(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value;
}

function validatePeriodConfiguration(card: CreditCard): void {
  const reward = card.rewardPeriod;
  if (reward && (!Number.isInteger(reward.monthCount) || reward.monthCount < 2 || reward.monthCount > 24 ||
    !isCalendarDate(reward.anchorDate))) {
    throw new ValidationError(`Invalid reward period for card ${card.id}`);
  }
  const day = card.billingCycle?.dayOfMonth;
  if (card.billingCycle?.type === "billing" && day != null && (!Number.isInteger(day) || day < 1 || day > 31)) {
    throw new ValidationError(`Invalid billing cycle for card ${card.id}`);
  }
}

function serializeCalculation(card: CreditCard, calculation: SimplifiedCalculation): RewardsCardCalculation {
  const tier = resolveCardSpendingTier(card, calculation.totalSpend);
  return {
    period: calculation.period,
    total_spend: calculation.totalSpend,
    counted_spend: calculation.countedSpend,
    eligible_spend: calculation.eligibleSpend,
    reward_earned: calculation.rewardEarned,
    reward_earned_dollars: calculation.rewardEarnedDollars,
    reward_type: calculation.rewardType,
    minimum_spend: calculation.minimumSpend ?? null,
    minimum_spend_met: calculation.minimumSpendMet,
    minimum_spend_progress: calculation.minimumSpendProgress ?? null,
    maximum_spend: calculation.maximumSpend ?? null,
    maximum_spend_exceeded: calculation.maximumSpendExceeded,
    maximum_spend_progress: calculation.maximumSpendProgress ?? null,
    qualification_status: calculation.qualificationStatus,
    monthly_qualifications: calculation.monthlyQualifications,
    monthly_minimum_spend: calculation.monthlyMinimumSpend,
    active_spending_tier_id: calculation.activeSpendingTierId,
    has_next_spending_tier: tier.hasNextSpendingTier,
    next_spending_tier_id: tier.nextLevel?.id ?? null,
    next_spending_tier_threshold: tier.nextLevel?.spendThreshold ?? null,
    should_stop_using: calculation.maximumSpendExceeded && !tier.hasNextSpendingTier,
    flags: (calculation.subcategoryBreakdowns ?? []).map(({ id, active, excluded, ...row }) => ({ subcategoryId: id, ...row })),
  };
}

/** Keep final-period rates/qualification, but subtract cap usage before the selected slice. */
function attributeCalculation(
  card: CreditCard,
  history: Transaction[],
  transactions: Transaction[],
  period: CalculationPeriod,
  calculation: SimplifiedCalculation,
  settings: AppSettings,
): RewardsCardCalculation {
  const full = serializeCalculation(card, calculation);
  // Freeze the tier reached with complete history: a cut-in range must not resolve a new tier.
  const effective = resolveCardSpendingTier(card, calculation.totalSpend).effectiveCard;
  const effectiveCard = {
    ...effective, spendingTiers: undefined, rewardPeriod: undefined, minimumSpend: 0,
    subcategories: effective.subcategories?.map((flag) => ({ ...flag, minimumSpend: 0 })),
  };
  // A promotion can interrupt a calendar window. Subtract prefixes for each
  // contiguous selected slice so interrupted spend is never attributed twice.
  const selectedDates = new Set(transactions.map((t) => t.date));
  const ranges: Array<{ first: string; last: string }> = [];
  let range: { first: string; last: string } | undefined;
  for (const date of [...new Set(history.map((t) => t.date))].sort()) {
    if (!selectedDates.has(date)) {
      range = undefined;
    } else if (range) {
      range.last = date;
    } else {
      range = { first: date, last: date };
      ranges.push(range);
    }
  }
  const prefixes = ranges.map(({ first, last }) => ({
    before: SimpleRewardsCalculator.calculateCardRewards(effectiveCard, history.filter((t) => t.date < first), period, settings),
    through: SimpleRewardsCalculator.calculateCardRewards(effectiveCard, history.filter((t) => t.date <= last), period, settings),
  }));
  const difference = (value: (result: SimplifiedCalculation) => number): number =>
    prefixes.reduce((sum, { before, through }) => sum + value(through) - value(before), 0);
  const selected = SimpleRewardsCalculator.calculateCardRewards(effectiveCard, transactions, period, settings);
  const rewards = transactions.map((t) => calculation.transactionRewards[t.id]).filter((r) => r != null);
  const flags = full.flags.map((flag) => {
    const slice = selected.subcategoryBreakdowns?.find((f) => f.id === flag.subcategoryId);
    const flagDifference = (field: "countedSpend" | "eligibleSpendBeforeBlocks" | "rewardEarned" | "rewardEarnedDollars" | "blocksEarned") =>
      difference((result) => result.subcategoryBreakdowns?.find((f) => f.id === flag.subcategoryId)?.[field] ?? 0);
    const counted = flagDifference("countedSpend");
    return {
      ...flag,
      totalSpend: slice?.totalSpend ?? 0,
      countedSpend: counted,
      eligibleSpend: flag.minimumSpendMet ? counted : 0,
      eligibleSpendBeforeBlocks: flag.minimumSpendMet ? flagDifference("eligibleSpendBeforeBlocks") : 0,
      rewardEarned: flag.minimumSpendMet ? flagDifference("rewardEarned") : 0,
      rewardEarnedDollars: flag.minimumSpendMet ? flagDifference("rewardEarnedDollars") : 0,
      blocksEarned: flag.minimumSpendMet ? flagDifference("blocksEarned") : 0,
    };
  });
  return {
    ...full,
    total_spend: selected.totalSpend,
    counted_spend: difference((result) => result.countedSpend),
    eligible_spend: flags.length ? flags.reduce((sum, flag) => sum + flag.eligibleSpend, 0) : full.minimum_spend_met ? difference((result) => result.countedSpend) : 0,
    reward_earned: rewards.reduce((sum, r) => sum + r.reward, 0),
    reward_earned_dollars: rewards.reduce((sum, r) => sum + r.rewardDollars, 0),
    flags,
  };
}

export function milliunitsToUnits(amountMilli: number): number {
  return amountMilli / MILLIUNITS_PER_UNIT;
}

function groupTransactions(
  transactions: Transaction[],
  groupBy: RewardGroupBy,
  rewards: Map<string, { reward: number; rewardDollars: number }>,
): RewardGroupRow[] {
  const buckets = new Map<string, RewardGroupRow>();
  for (const transaction of transactions) {
    if (transaction.amount >= 0) continue;
    const spend = Math.abs(transaction.amount) / MILLIUNITS_PER_UNIT;
    const earned = rewards.get(transaction.id) ?? { reward: 0, rewardDollars: 0 };
    const grouped = groupKey(transaction, groupBy);
    const existing = buckets.get(grouped.key) ?? {
      key: grouped.key,
      label: grouped.label,
      flag_color: grouped.flagColor,
      spend: 0,
      reward: 0,
      reward_dollars: 0,
      transaction_count: 0,
    };
    existing.spend += spend;
    existing.reward += earned.reward;
    existing.reward_dollars += earned.rewardDollars;
    existing.transaction_count += 1;
    buckets.set(grouped.key, existing);
  }
  return [...buckets.values()].sort((left, right) => right.spend - left.spend || left.key.localeCompare(right.key));
}

function groupKey(transaction: Transaction, groupBy: RewardGroupBy): {
  key: string;
  label: string;
  flagColor: string | null;
} {
  if (groupBy === "flag") {
    const colour = transaction.flag_color ?? "unflagged";
    return {
      key: `flag:${colour}`,
      label: transaction.flag_name?.trim() || titleCase(colour),
      flagColor: transaction.flag_color ?? null,
    };
  }
  if (groupBy === "payee") {
    const label = transaction.payee_name?.trim() || "Unknown payee";
    return { key: `payee:${label}`, label, flagColor: null };
  }
  if (groupBy === "category") {
    const label = transaction.category_name?.trim() || "Uncategorised";
    return { key: `category:${label}`, label, flagColor: null };
  }
  const memo = transaction.memo?.trim();
  return {
    key: `memo:${memo ?? ""}`,
    label: memo || "No memo",
    flagColor: null,
  };
}

function titleCase(value: string): string {
  if (!value) return value;
  return value[0]!.toUpperCase() + value.slice(1);
}
