import type { Transaction } from "./types";

export function mapRewardTransactionRow(row: {
  id: string;
  date: string;
  amount_milli: number | string;
  account_id: string;
  account_name?: string | null;
  flag_color?: string | null;
  flag_name?: string | null;
  memo?: string | null;
  payee_name?: string | null;
  category_name?: string | null;
  transfer_account_id?: string | null;
}): Transaction {
  return {
    id: String(row.id),
    date: String(row.date),
    amount: Number(row.amount_milli),
    account_id: String(row.account_id),
    flag_color: row.flag_color ?? null,
    flag_name: row.flag_name ?? null,
    memo: row.memo ?? null,
    payee_name: row.payee_name ?? null,
    category_name: row.category_name ?? null,
    transfer_account_id: row.transfer_account_id ?? null,
  };
}
