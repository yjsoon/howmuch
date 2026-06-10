import type { Interval } from "../api/types";
import { splitCategoryGroups, UNCATEGORISED_CATEGORY_ID } from "../lib/categories";
import {
  calendarMonthOf,
  formatDateRange,
  formatMonthName,
  matchPreset,
  RANGE_PRESETS,
  shiftMonth,
} from "../lib/dates";
import { usePlan } from "../state/plan";
import type { Filters } from "../state/filters";
import { MultiSelect, type MultiSelectOption } from "./MultiSelect";

interface Props {
  filters: Filters;
  setFilters: (patch: Partial<Filters>) => void;
  /** Intervals this report supports; omit to hide the segmented control. */
  intervals?: Interval[];
  showCategories?: boolean;
  /** Shows a quiet progress stripe along the rail while a report refetches. */
  busy?: boolean;
}

export function FilterRail({ filters, setFilters, intervals, showCategories = true, busy = false }: Props) {
  const { accounts, categoryGroups } = usePlan();
  const activePreset = matchPreset(filters.from, filters.to);
  const month = calendarMonthOf(filters.from, filters.to);

  const accountOptions = accounts
    .filter((account) => !account.closed)
    .map((account) => ({ id: account.id, label: account.name }));

  const { primary, quiet } = splitCategoryGroups(categoryGroups);
  const categoryOptions: MultiSelectOption[] = [
    ...primary.flatMap((group) =>
      group.categories.map((category) => ({ id: category.id, label: category.name, group: group.name })),
    ),
    { id: UNCATEGORISED_CATEGORY_ID, label: "Uncategorised", group: "Needs a category", muted: true },
    ...quiet.flatMap((group) =>
      group.categories.map((category) => ({
        id: category.id,
        label: category.name,
        group: group.name,
        muted: true,
      })),
    ),
  ];

  const selectedInterval = intervals?.includes(filters.interval) ? filters.interval : intervals?.[0];
  const hasActiveFilters = Boolean(
    filters.from ||
      filters.to ||
      filters.accountIds.length ||
      (showCategories && filters.categoryIds.length) ||
      (selectedInterval && selectedInterval !== "month"),
  );

  const summary = [
    formatDateRange(filters.from, filters.to),
    filters.accountIds.length
      ? `${filters.accountIds.length} account${filters.accountIds.length === 1 ? "" : "s"}`
      : "All accounts",
    showCategories
      ? filters.categoryIds.length
        ? `${filters.categoryIds.length} categor${filters.categoryIds.length === 1 ? "y" : "ies"}`
        : "All categories"
      : null,
    selectedInterval ? `${selectedInterval} intervals` : null,
  ]
    .filter(Boolean)
    .join(" · ");

  return (
    <div className="filter-stack">
      <div className={busy ? "filter-rail filter-rail-busy" : "filter-rail"}>
        {month && (
          <div className="filter-cluster">
            <span className="rail-label">Month</span>
            <div className="month-stepper" role="group" aria-label="Month">
              <button
                type="button"
                className="month-step"
                onClick={() => setFilters(shiftMonth(month, -1))}
                aria-label="Previous month"
              >
                ‹
              </button>
              <span className="month-label">{formatMonthName(month)}</span>
              <button
                type="button"
                className="month-step"
                onClick={() => setFilters(shiftMonth(month, 1))}
                aria-label="Next month"
              >
                ›
              </button>
            </div>
          </div>
        )}

        <div className="filter-cluster">
          <span className="rail-label">Range</span>
          <div className="segmented" role="group" aria-label="Date range">
            {RANGE_PRESETS.map((preset) => (
              <button
                key={preset.id}
                type="button"
                className={preset.id === activePreset ? "segment segment-active" : "segment"}
                onClick={() => setFilters(preset.range())}
              >
                {preset.label}
              </button>
            ))}
          </div>
        </div>

        <div className="filter-cluster">
          <span className="rail-label">Dates</span>
          <div className="custom-range">
            <input
              type="date"
              value={filters.from ?? ""}
              onChange={(event) => setFilters({ from: event.target.value || undefined, to: filters.to })}
              aria-label="From date"
            />
            <span className="range-dash">-</span>
            <input
              type="date"
              value={filters.to ?? ""}
              onChange={(event) => setFilters({ from: filters.from, to: event.target.value || undefined })}
              aria-label="To date"
            />
          </div>
        </div>

        <div className="filter-cluster">
          <span className="rail-label">Scope</span>
          <div className="filter-actions">
            <MultiSelect
              label="Accounts"
              options={accountOptions}
              selected={filters.accountIds}
              onChange={(accountIds) => setFilters({ accountIds })}
            />

            {showCategories && (
              <MultiSelect
                label="Categories"
                options={categoryOptions}
                selected={filters.categoryIds}
                onChange={(categoryIds) => setFilters({ categoryIds })}
              />
            )}
          </div>
        </div>

        {intervals && (
          <div className="filter-cluster">
            <span className="rail-label">Interval</span>
            <div className="segmented" role="group" aria-label="Interval">
              {intervals.map((interval) => (
                <button
                  key={interval}
                  type="button"
                  className={interval === filters.interval ? "segment segment-active" : "segment"}
                  onClick={() => setFilters({ interval })}
                >
                  {interval[0].toUpperCase() + interval.slice(1)}
                </button>
              ))}
            </div>
          </div>
        )}
      </div>

      <div className="filter-summary">
        <span className="filter-summary-text">{summary}</span>
        <div className="filter-actions">
          {hasActiveFilters && (
            <button
              type="button"
              className="text-button"
              onClick={() =>
                setFilters({
                  from: undefined,
                  to: undefined,
                  accountIds: [],
                  categoryIds: [],
                  interval: intervals?.includes("month") ? "month" : (intervals?.[0] ?? "month"),
                })
              }
            >
              Clear filters
            </button>
          )}
        </div>
      </div>
    </div>
  );
}
