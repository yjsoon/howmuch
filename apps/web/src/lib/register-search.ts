import {
  DEFAULT_MONEY_FORMAT,
  matchesRegisterQuery,
  parseRegisterQuery,
  type MoneyFormat,
  type RegisterQuery,
  type SearchableFields,
} from "@howmuch/register-query";
import type { CurrencyFormat, ScheduledTransaction, Transaction } from "../api/types";

export { parseRegisterQuery, matchesRegisterQuery };

export function moneyFormatFromPlan(format?: CurrencyFormat | null): MoneyFormat {
  return {
    decimalDigits: format?.decimal_digits ?? DEFAULT_MONEY_FORMAT.decimalDigits,
    decimalSeparator: format?.decimal_separator ?? DEFAULT_MONEY_FORMAT.decimalSeparator,
    groupSeparator: format?.group_separator ?? DEFAULT_MONEY_FORMAT.groupSeparator,
    currencySymbol: format?.currency_symbol ?? DEFAULT_MONEY_FORMAT.currencySymbol,
  };
}

export function fieldsFromTransaction(transaction: Transaction): SearchableFields {
  return {
    payeeName: transaction.payee_name,
    memo: transaction.memo,
    categoryName: transaction.category_name,
    accountName: transaction.account_name,
    amountMilli: transaction.amount,
    lines: transaction.subtransactions?.map((line) => ({
      payeeName: line.payee_name,
      memo: line.memo,
      categoryName: line.category_name,
      amountMilli: line.amount,
    })),
  };
}

export function fieldsFromSchedule(
  schedule: ScheduledTransaction,
  names: { accountName?: string; payeeName?: string },
): SearchableFields {
  return {
    payeeName: schedule.payee_name ?? names.payeeName,
    memo: schedule.memo,
    categoryName: schedule.category_name,
    accountName: names.accountName,
    amountMilli: schedule.amount,
    lines: schedule.subtransactions?.map((line) => ({
      payeeName: line.payee_name,
      memo: line.memo,
      categoryName: line.category_name,
      amountMilli: line.amount,
    })),
  };
}

export function transactionMatchesQuery(query: RegisterQuery | null, transaction: Transaction): boolean {
  return !query || matchesRegisterQuery(query, fieldsFromTransaction(transaction));
}

export function mergeSearchRows(local: Transaction[], hits: Transaction[]): Transaction[] {
  const seen = new Set<string>();
  const merged: Transaction[] = [];
  for (const row of [...hits, ...local]) {
    if (seen.has(row.id)) {
      continue;
    }
    seen.add(row.id);
    merged.push(row);
  }
  return merged.sort((left, right) => (left.date < right.date ? 1 : left.date > right.date ? -1 : 0));
}

export function searchStatusCopy(input: {
  shown: number;
  scheduled: number;
  hasMore: boolean;
  loading: boolean;
  error: string | null;
}): string {
  if (input.loading) {
    return "Searching all transactions…";
  }
  if (input.error) {
    return "Couldn’t search older transactions. Showing matches from recent transactions.";
  }
  const scheduled =
    input.scheduled === 0
      ? ""
      : ` and ${input.scheduled} scheduled ${input.scheduled === 1 ? "transaction" : "transactions"}`;
  if (input.hasMore) {
    return `Showing ${input.shown} matches so far. Load older matches to see more.`;
  }
  return `${input.shown} matching ${input.shown === 1 ? "transaction" : "transactions"}${scheduled}`;
}
