import { splitCategoryGroups } from "../lib/categories";

export function CategorySelect({
  value,
  onChange,
  groups,
  allowEmpty = true,
  emptyLabel = "Uncategorised",
  disabled = false,
  "aria-label": ariaLabel,
}: {
  value: string;
  onChange: (value: string) => void;
  groups: ReturnType<typeof splitCategoryGroups>;
  allowEmpty?: boolean;
  emptyLabel?: string;
  disabled?: boolean;
  "aria-label"?: string;
}) {
  return (
    <select
      value={value}
      onChange={(event) => onChange(event.target.value)}
      aria-label={ariaLabel}
      disabled={disabled}
    >
      {allowEmpty && <option value="">{emptyLabel}</option>}
      {[...groups.primary, ...groups.quiet].map((group) => (
        <optgroup key={group.id} label={group.name}>
          {group.categories.map((category) => (
            <option key={category.id} value={category.id}>
              {category.name}
            </option>
          ))}
        </optgroup>
      ))}
    </select>
  );
}
