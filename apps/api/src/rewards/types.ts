import type { YnabFlagColor } from "./flags";

export interface Transaction {
  id: string;
  date: string;
  amount: number;
  account_id: string;
  transfer_account_id?: string | null;
  transfer_transaction_id?: string | null;
  payee_name?: string | null;
  category_name?: string | null;
  memo?: string | null;
  cleared?: string | null;
  approved?: boolean;
  flag_color?: string | null;
  flag_name?: string | null;
  subtransactions?: Transaction[];
}

export interface CardSubcategory {
  id: string;
  name: string;
  flagColor: YnabFlagColor;
  rewardValue: number;
  milesBlockSize?: number | null;
  minimumSpend?: number | null;
  maximumSpend?: number | null;
  priority: number;
  active: boolean;
  excludeFromRewards?: boolean;
  createdAt: string;
  updatedAt: string;
}

export interface SpendingTierSubcategory {
  subcategoryId: string;
  rewardValue: number;
  maximumSpend?: number | null;
}

export interface CardSpendingTier {
  id: string;
  spendThreshold: number;
  earningRate?: number | null;
  maximumSpend?: number | null;
  subcategories?: SpendingTierSubcategory[];
}

export interface CardRewardPeriod {
  monthCount: number;
  anchorDate: string;
  monthlyMinimumSpend: number;
}

export interface CreditCard {
  id: string;
  name: string;
  issuer: string;
  type: "cashback" | "miles";
  ynabAccountId: string;
  billingCycle?: {
    type: "calendar" | "billing";
    dayOfMonth?: number;
  };
  rewardPeriod?: CardRewardPeriod;
  promotionalPeriod?: {
    startDate?: string | null;
    endDate: string;
    description?: string;
  };
  featured: boolean;
  earningRate?: number | null;
  earningBlockSize?: number | null;
  minimumSpend?: number | null;
  maximumSpend?: number | null;
  subcategoriesEnabled?: boolean;
  subcategories?: CardSubcategory[];
  spendingTiers?: CardSpendingTier[];
  flagNames?: Record<string, string>;
}

export type MonthlyQualificationStatus = "met" | "pending" | "failed";

export interface MonthlyQualificationBreakdown {
  start: string;
  end: string;
  spend: number;
  minimumSpend: number;
  status: MonthlyQualificationStatus;
}

export type RewardQualificationStatus = "not_required" | "met" | "pending" | "failed";

export interface CategoryBreakdown {
  category: string;
  spend: number;
  reward: number;
  rewardDollars?: number;
  capReached: boolean;
}

export interface SubcategoryBreakdown {
  subcategoryId: string;
  name: string;
  flagColor: YnabFlagColor;
  totalSpend: number;
  countedSpend?: number;
  eligibleSpend: number;
  eligibleSpendBeforeBlocks?: number;
  rewardEarned: number;
  rewardEarnedDollars?: number;
  rewardRate?: number;
  minimumSpend?: number | null;
  minimumSpendMet: boolean;
  maximumSpend?: number | null;
  maximumSpendExceeded: boolean;
  blockSize?: number | null;
  blocksEarned?: number;
}

export interface RewardCalculation {
  cardId: string;
  ruleId: string;
  period: string;
  totalSpend: number;
  countedSpend?: number;
  eligibleSpend: number;
  eligibleSpendBeforeBlocks?: number;
  rewardEarned: number;
  rewardEarnedDollars?: number;
  rewardType: "cashback" | "miles";
  categoryBreakdowns?: CategoryBreakdown[];
  subcategoryBreakdowns?: SubcategoryBreakdown[];
  minimumSpend?: number | null;
  minimumProgress?: number;
  monthlyMinimumSpend?: number;
  qualificationStatus?: RewardQualificationStatus;
  monthlyQualifications?: MonthlyQualificationBreakdown[];
  rewardPeriodCalculationVersion?: number;
  maximumSpend?: number | null;
  maximumProgress?: number;
  activeSpendingTierId?: string | null;
  spendingTierCalculationVersion?: number;
  minimumMet: boolean;
  maximumExceeded: boolean;
  shouldStopUsing: boolean;
}

export type DashboardViewMode = "summary" | "detailed";

export interface AppSettings {
  theme?: "light" | "dark" | "auto";
  currency?: string;
  milesValuation?: number;
  dashboardViewMode?: DashboardViewMode;
  groupCardsByType?: boolean;
  cardOrdering?: Partial<Record<"cashback" | "miles" | "all", string[]>>;
  collapsedCardGroups?: Partial<Record<"cashback" | "miles", boolean>>;
}

export type RewardGroupBy = "flag" | "payee" | "category" | "memo";

export interface RewardGroupRow {
  key: string;
  label: string;
  flag_color: string | null;
  spend: number;
  reward: number;
  reward_dollars: number;
  transaction_count: number;
}

export interface RewardsCardRow {
  card: CreditCard;
  account_id: string;
  account_name: string;
  calculation: RewardsCardCalculation & {
    /** Full-period state; card-level amounts are attributed to the requested range. */
    periods?: Array<{ start: string; end: string; calculation: RewardsCardCalculation }>;
  };
}

export interface RewardsCardCalculation {
  period: string;
  total_spend: number;
  counted_spend: number;
  eligible_spend: number;
  reward_earned: number;
  reward_earned_dollars: number;
  reward_type: "cashback" | "miles";
  minimum_spend: number | null;
  minimum_spend_met: boolean;
  minimum_spend_progress: number | null;
  /** The first day of the period on which the minimum was met; null when not met or there is none. */
  minimum_met_on?: string | null;
  maximum_spend: number | null;
  maximum_spend_exceeded: boolean;
  maximum_spend_progress: number | null;
  qualification_status?: RewardQualificationStatus;
  monthly_qualifications?: MonthlyQualificationBreakdown[];
  monthly_minimum_spend?: number;
  active_spending_tier_id?: string | null;
  has_next_spending_tier?: boolean;
  next_spending_tier_id?: string | null;
  next_spending_tier_threshold?: number | null;
  should_stop_using?: boolean;
  flags: SubcategoryBreakdown[];
}

export interface RewardsReport {
  from: string | null;
  to: string | null;
  /** Effective cutoff, clamped to today's Asia/Singapore date. */
  as_of?: string;
  period?: string;
  transaction_rewards?: Record<string, { reward: number; reward_dollars: number }>;
  group_by: RewardGroupBy;
  miles_valuation: number;
  totals: {
    spend: number;
    reward_dollars: number;
    cashback: number;
    miles: number;
  };
  cards: RewardsCardRow[];
  groups: RewardGroupRow[];
}
