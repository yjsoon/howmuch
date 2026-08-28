import { trailingMonthsRange } from "./dates";

export const REGISTER_HORIZON_MONTHS = 2;
export const REGISTER_HORIZON_MAX_ROWS = 600;

export function horizonStartDate(today: string): string {
  const [year, month, day] = today.split("-").map(Number);
  return trailingMonthsRange(REGISTER_HORIZON_MONTHS, new Date(year, month - 1, day)).from;
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

export async function fillRegisterHorizon<T extends { id: string; date: string }>(options: {
  today: string;
  fetchPage: (offset: number) => Promise<RegisterHorizonPage<T>>;
  isCurrent: () => boolean;
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
    const oldestLoadedDate = loaded.reduce<string | null>(
      (oldest, transaction) => (oldest === null || transaction.date < oldest ? transaction.date : oldest),
      null,
    );
    if (
      nextOffset === null
      || !shouldFetchMoreForHorizon({
        oldestLoadedDate,
        hasMore,
        rowCount: loaded.length,
        today: options.today,
      })
    ) {
      return { transactions: loaded, hasMore, nextOffset };
    }

    offset = nextOffset;
    pageIndex += 1;
  }
}
