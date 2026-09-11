import { trailingMonthsRange } from "./dates";

export const REGISTER_HORIZON_MONTHS = 2;
export const REGISTER_HORIZON_MAX_ROWS = 600;

// Matches the server's MAX_TRANSACTION_PAGE_SIZE (apps/api/src/types.ts) so the
// horizon fill can complete in as few requests as the API allows.
export const REGISTER_PAGE_SIZE = 250;

export function horizonStartDate(today: string): string {
  const [year, month, day] = today.split("-").map(Number);
  return trailingMonthsRange(REGISTER_HORIZON_MONTHS, new Date(year, month - 1, day)).from;
}

export function oldestDateForHorizonCoverage<T extends { date: string; account_id?: string }>(
  rows: T[],
  accountId?: string | null,
): string | null {
  const scoped = accountId ? rows.filter((row) => row.account_id === accountId) : rows;
  return scoped.reduce<string | null>(
    (oldest, row) => (oldest === null || row.date < oldest ? row.date : oldest),
    null,
  );
}

export function shouldFetchMoreForHorizon(input: {
  oldestLoadedDate: string | null;
  hasMore: boolean;
  rowCount: number;
  today: string;
}): boolean {
  if (!input.hasMore || input.rowCount >= REGISTER_HORIZON_MAX_ROWS) {
    return false;
  }
  return input.oldestLoadedDate === null || input.oldestLoadedDate >= horizonStartDate(input.today);
}

export interface RegisterHorizonPage<T extends { id: string; date: string }> {
  transactions: T[];
  has_more: boolean;
  next_offset: number | null;
}

export interface RegisterHorizonFill<T extends { id: string; date: string }> {
  transactions: T[];
  hasMore: boolean;
  nextOffset: number | null;
}

export async function fillRegisterHorizon<T extends { id: string; date: string; account_id?: string }>(options: {
  today: string;
  accountId?: string | null;
  fetchPage: (offset: number) => Promise<RegisterHorizonPage<T>>;
  isCurrent: () => boolean;
  onProgress?: (update: RegisterHorizonFill<T> & { done: boolean }) => void;
}): Promise<RegisterHorizonFill<T> | null> {
  const loaded: T[] = [];
  const seen = new Set<string>();
  let hasMore = false;
  let nextOffset: number | null = null;
  let offset = 0;
  let pageIndex = 0;

  for (;;) {
    let page: RegisterHorizonPage<T>;
    try {
      page = await options.fetchPage(offset);
    } catch (error) {
      if (pageIndex === 0) {
        throw error;
      }
      return options.isCurrent() ? { transactions: loaded, hasMore: true, nextOffset } : null;
    }
    if (!options.isCurrent()) {
      return null;
    }

    for (const transaction of page.transactions) {
      if (seen.has(transaction.id)) {
        continue;
      }
      seen.add(transaction.id);
      loaded.push(transaction);
    }

    hasMore = page.has_more && page.next_offset !== null;
    nextOffset = hasMore ? page.next_offset : null;
    const oldestLoadedDate = oldestDateForHorizonCoverage(loaded, options.accountId);
    const fill = { transactions: loaded.slice(), hasMore, nextOffset };
    const done =
      nextOffset === null
      || !shouldFetchMoreForHorizon({
        oldestLoadedDate,
        hasMore,
        rowCount: options.accountId
          ? loaded.filter((row) => row.account_id === options.accountId).length
          : loaded.length,
        today: options.today,
      });
    options.onProgress?.({ ...fill, done });
    if (done || nextOffset === null) {
      return fill;
    }

    offset = nextOffset;
    pageIndex += 1;
  }
}
