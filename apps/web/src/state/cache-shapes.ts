/**
 * The shapes the cache stores, and the guards that decide whether something
 * read back from storage is still one of them.
 *
 * The guards are deliberately structural rather than exhaustive. Their job is
 * not to re-validate the server; it is to reject a payload written by an older
 * build, a half-finished write, or another tab, so a shape change can never
 * reach a component as a crash. Anything they reject is simply refetched.
 */

import type {
  Account,
  AccountPreferencesSnapshot,
  CategoryGroup,
  PlanSettings,
  Payee,
  ScheduledTransaction,
  Transaction,
} from "../api/types";

/** The reference batch `PlanProvider` needs before it can render a plan. */
export interface CachedReference {
  settings: PlanSettings;
  categoryGroups: CategoryGroup[];
  accounts: Account[];
  /** null means the server reported no preferences, or did not support them. */
  accountPreferences: AccountPreferencesSnapshot | null;
}

/** The register's first page, kept only to seed a network-first fetch. */
export interface CachedRegisterPage {
  /** The account and date window the page was fetched for. */
  listKey: string;
  transactions: Transaction[];
  hasMore: boolean;
  nextOffset: number | null;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isArrayOf(value: unknown, item: (entry: unknown) => boolean): boolean {
  return Array.isArray(value) && value.every(item);
}

function hasStringId(value: unknown): boolean {
  return isObject(value) && typeof value.id === "string" && value.id !== "";
}

function isAccount(value: unknown): boolean {
  return hasStringId(value)
    && typeof (value as Record<string, unknown>).name === "string"
    && typeof (value as Record<string, unknown>).balance === "number";
}

function isCategoryGroup(value: unknown): boolean {
  if (!hasStringId(value)) return false;
  const group = value as Record<string, unknown>;
  return typeof group.name === "string" && isArrayOf(group.categories, hasStringId);
}

function isPayee(value: unknown): boolean {
  return hasStringId(value) && typeof (value as Record<string, unknown>).name === "string";
}

function isTransaction(value: unknown): boolean {
  if (!hasStringId(value)) return false;
  const transaction = value as Record<string, unknown>;
  return typeof transaction.date === "string"
    && typeof transaction.amount === "number"
    && typeof transaction.account_id === "string";
}

export function isCachedReference(value: unknown): value is CachedReference {
  if (!isObject(value)) return false;
  if (!isObject(value.settings)) return false;
  if (!isArrayOf(value.categoryGroups, isCategoryGroup)) return false;
  if (!isArrayOf(value.accounts, isAccount)) return false;
  const preferences = value.accountPreferences;
  if (preferences !== null) {
    if (!isObject(preferences)) return false;
    if (typeof preferences.account_preferences_revision !== "number") return false;
  }
  return true;
}

export function isCachedPayees(value: unknown): value is Payee[] {
  return isArrayOf(value, isPayee);
}

export function isCachedScheduled(value: unknown): value is ScheduledTransaction[] {
  return isArrayOf(value, hasStringId);
}

export function isCachedRegisterPage(value: unknown): value is CachedRegisterPage {
  if (!isObject(value)) return false;
  if (typeof value.listKey !== "string" || value.listKey === "") return false;
  if (!isArrayOf(value.transactions, isTransaction)) return false;
  if (typeof value.hasMore !== "boolean") return false;
  return value.nextOffset === null || typeof value.nextOffset === "number";
}
