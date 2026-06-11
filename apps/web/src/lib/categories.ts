import type { CategoryGroup } from "../api/types";

/** Matches the API's COALESCE id for transactions without a category. */
export const UNCATEGORISED_CATEGORY_ID = "uncategorised";

/**
 * Bookkeeping groups the YNAB import carries as ordinary groups ("Hidden
 * Categories", "Non-Personal (Don't Summarise)", inflows). They are real data
 * but not part of day-to-day budgeting, so pickers and reports demote them.
 */
const QUIET_GROUP_NAME = /hidden|non.personal|don.t summari[sz]e|inflow|credit card payments|internal/i;

export function isQuietGroupName(name: string | null | undefined): boolean {
  return name != null && QUIET_GROUP_NAME.test(name);
}

export function isQuietGroup(group: Pick<CategoryGroup, "name" | "hidden">): boolean {
  return Boolean(group.hidden) || isQuietGroupName(group.name);
}

export interface SplitGroups {
  primary: CategoryGroup[];
  quiet: CategoryGroup[];
}

/** Live groups with live categories, partitioned into everyday and bookkeeping ones. */
export function splitCategoryGroups(groups: CategoryGroup[]): SplitGroups {
  const primary: CategoryGroup[] = [];
  const quiet: CategoryGroup[] = [];
  for (const group of groups) {
    if (group.deleted) {
      continue;
    }
    const categories = (group.categories ?? []).filter((category) => !category.deleted);
    if (!categories.length) {
      continue;
    }
    (isQuietGroup(group) ? quiet : primary).push({ ...group, categories });
  }
  return { primary, quiet };
}
