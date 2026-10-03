type GroupRow = Record<string, any>;

export type IncomeVsSpendingGroupsReport = {
  income: number;
  spending: number;
  net: number;
  income_by_payee: Array<{
    payee_id: string | null;
    payee_name: string;
    amount: number;
    share: number;
    transaction_count: number;
    category_id: string | null;
    category_name: string;
    category_count: number;
  }>;
  income_by_category: Array<{
    category_id: string;
    category_name: string;
    amount: number;
    share: number;
    transaction_count: number;
  }>;
  spending_by_category: Array<{
    category_id: string;
    category_name: string;
    category_group_id: string;
    category_group_name: string;
    amount: number;
    share: number;
    transaction_count: number;
  }>;
};

const NO_PAYEE = "No payee";
const MULTIPLE_CATEGORIES = "Multiple categories";

function share(amount: number, total: number): number {
  return total > 0 ? amount / total : 0;
}

function compareAmountThenName(left: { amount: number; name: string }, right: { amount: number; name: string }): number {
  if (right.amount !== left.amount) {
    return right.amount - left.amount;
  }
  return left.name.localeCompare(right.name);
}

export function assembleIncomeVsSpendingGroups(input: {
  income: number;
  spending: number;
  incomeByPayee: GroupRow[];
  incomeByCategory: GroupRow[];
  spendingByCategory: GroupRow[];
}): IncomeVsSpendingGroupsReport {
  const income = Number(input.income ?? 0);
  const spending = Number(input.spending ?? 0);

  const incomeByPayee = input.incomeByPayee.map((row) => {
    const amount = Number(row.amount ?? 0);
    const categoryCount = Number(row.category_count ?? 0);
    const rawCategoryId = row.category_id == null ? null : String(row.category_id);
    const rawCategoryName = row.category_name == null ? "Uncategorised" : String(row.category_name);
    return {
      payee_id: row.payee_id == null || row.payee_id === "" ? null : String(row.payee_id),
      payee_name: String(row.payee_name ?? NO_PAYEE),
      amount,
      share: share(amount, income),
      transaction_count: Number(row.transaction_count ?? 0),
      category_id: categoryCount === 1 ? rawCategoryId : null,
      category_name: categoryCount === 1 ? rawCategoryName : MULTIPLE_CATEGORIES,
      category_count: categoryCount,
    };
  }).sort((left, right) => {
    if (right.amount !== left.amount) {
      return right.amount - left.amount;
    }
    const leftLast = left.payee_name === NO_PAYEE;
    const rightLast = right.payee_name === NO_PAYEE;
    if (leftLast !== rightLast) {
      return leftLast ? 1 : -1;
    }
    return left.payee_name.localeCompare(right.payee_name);
  });

  const incomeByCategory = input.incomeByCategory.map((row) => {
    const amount = Number(row.amount ?? 0);
    return {
      category_id: String(row.category_id ?? "uncategorised"),
      category_name: String(row.category_name ?? "Uncategorised"),
      amount,
      share: share(amount, income),
      transaction_count: Number(row.transaction_count ?? 0),
    };
  }).sort((left, right) => compareAmountThenName(
    { amount: left.amount, name: left.category_name },
    { amount: right.amount, name: right.category_name },
  ));

  const spendingByCategory = input.spendingByCategory.map((row) => {
    const amount = Number(row.amount ?? 0);
    return {
      category_id: String(row.category_id ?? "uncategorised"),
      category_name: String(row.category_name ?? "Uncategorised"),
      category_group_id: String(row.category_group_id ?? "uncategorised-group"),
      category_group_name: String(row.category_group_name ?? "Uncategorised"),
      amount,
      share: share(amount, spending),
      transaction_count: Number(row.transaction_count ?? 0),
    };
  }).sort((left, right) => compareAmountThenName(
    { amount: left.amount, name: left.category_name },
    { amount: right.amount, name: right.category_name },
  ));

  return {
    income,
    spending,
    net: income - spending,
    income_by_payee: incomeByPayee,
    income_by_category: incomeByCategory,
    spending_by_category: spendingByCategory,
  };
}
