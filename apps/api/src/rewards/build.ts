import { SimpleRewardsCalculator, type CalculationPeriod } from "./engine/simple-calculator";
import type {
  AppSettings,
  CreditCard,
  RewardGroupBy,
  RewardGroupRow,
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
  groupBy: RewardGroupBy;
  accountIds: string[];
}): RewardsReport {
  const selected = new Set(input.accountIds);
  const cards = input.cards.filter((card) => {
    if (selected.size === 0) return true;
    return selected.has(card.ynabAccountId);
  });
  const cardAccountIds = new Set(cards.map((card) => card.ynabAccountId));
  const inRange = input.transactions.filter((transaction) => {
    if (!cardAccountIds.has(transaction.account_id)) return false;
    if (input.from && transaction.date < input.from) return false;
    if (input.to && transaction.date > input.to) return false;
    return true;
  });
  const dates = inRange.map((transaction) => transaction.date).sort();
  const period: CalculationPeriod = {
    start: input.from ?? dates[0] ?? "1970-01-01",
    end: input.to ?? dates[dates.length - 1] ?? "1970-01-01",
    label: input.from && input.to ? `${input.from}:${input.to}` : "all",
  };

  const rewardByTransaction = new Map<string, { reward: number; rewardDollars: number }>();
  const cardRows: RewardsCardRow[] = cards.map((card) => {
    const cardTransactions = inRange.filter((transaction) => transaction.account_id === card.ynabAccountId);
    const calculation = SimpleRewardsCalculator.calculateCardRewards(
      card,
      cardTransactions,
      period,
      input.settings,
    );
    for (const [id, result] of Object.entries(calculation.transactionRewards)) {
      rewardByTransaction.set(id, { reward: result.reward, rewardDollars: result.rewardDollars });
    }
    return {
      card,
      account_id: card.ynabAccountId,
      account_name: input.accountNames[card.ynabAccountId] ?? card.name,
      calculation: {
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
        flags: (calculation.subcategoryBreakdowns ?? []).map((row) => ({
          subcategoryId: row.id,
          name: row.name,
          flagColor: row.flagColor,
          totalSpend: row.totalSpend,
          countedSpend: row.countedSpend,
          eligibleSpend: row.eligibleSpend,
          eligibleSpendBeforeBlocks: row.eligibleSpendBeforeBlocks,
          rewardEarned: row.rewardEarned,
          rewardEarnedDollars: row.rewardEarnedDollars,
          rewardRate: row.rewardRate,
          minimumSpend: row.minimumSpend,
          minimumSpendMet: row.minimumSpendMet,
          maximumSpend: row.maximumSpend,
          maximumSpendExceeded: row.maximumSpendExceeded,
          blockSize: row.blockSize,
          blocksEarned: row.blocksEarned,
        })),
      },
    };
  });

  const groups = groupTransactions(inRange, input.groupBy, rewardByTransaction);

  return {
    from: input.from,
    to: input.to,
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
