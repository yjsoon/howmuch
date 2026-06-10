import type { Interval } from "../api/types";
import { matchPreset, RANGE_PRESETS } from "../lib/dates";
import { usePlan } from "../state/plan";
import type { Filters } from "../state/filters";
import { MultiSelect } from "./MultiSelect";

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

  const accountOptions = accounts
    .filter((account) => !account.closed)
    .map((account) => ({ id: account.id, label: account.name }));

  const categoryOptions = categoryGroups.flatMap((group) =>
    (group.categories ?? [])
      .filter((category) => !category.deleted)
      .map((category) => ({ id: category.id, label: category.name, group: group.name })),
  );

  return (
    <div className={busy ? "filter-rail filter-rail-busy" : "filter-rail"}>
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

      <div className="custom-range">
        <input
          type="date"
          name="from"
          value={filters.from ?? ""}
          onChange={(event) => setFilters({ from: event.target.value || undefined })}
          aria-label="From date"
        />
        <span className="range-dash">–</span>
        <input
          type="date"
          name="to"
          value={filters.to ?? ""}
          onChange={(event) => setFilters({ to: event.target.value || undefined })}
          aria-label="To date"
        />
      </div>

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

      {intervals && (
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
      )}
    </div>
  );
}
