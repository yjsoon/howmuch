import { FLAG_COLOURS, flagTitle, isFlagColour, type FlagColour } from "../lib/flags";

export function FlagTag({
  colour,
  name,
}: {
  colour: string | null | undefined;
  name?: string | null;
}) {
  if (!isFlagColour(colour)) return null;
  const label = flagTitle(colour, name);
  return (
    <span className={`flag-tag flag-tag-${colour}`} title={label}>
      {label}
    </span>
  );
}

export function FlagPicker({
  labelledBy,
  value,
  onChange,
  disabled,
}: {
  labelledBy?: string;
  value: string;
  onChange: (value: string) => void;
  disabled?: boolean;
}) {
  return (
    <div className="flag-picker" role="radiogroup" aria-labelledby={labelledBy}>
      <button
        type="button"
        role="radio"
        aria-checked={!value}
        className={value ? "flag-picker-none" : "flag-picker-none is-selected"}
        onClick={() => onChange("")}
        disabled={disabled}
      >
        None
      </button>
      {FLAG_COLOURS.map((colour) => (
        <FlagSwatch
          key={colour}
          colour={colour}
          selected={value === colour}
          disabled={disabled}
          onSelect={() => onChange(colour)}
        />
      ))}
    </div>
  );
}

function FlagSwatch({
  colour,
  selected,
  disabled,
  onSelect,
}: {
  colour: FlagColour;
  selected: boolean;
  disabled?: boolean;
  onSelect: () => void;
}) {
  return (
    <button
      type="button"
      role="radio"
      aria-checked={selected}
      aria-label={flagTitle(colour)}
      className={selected ? `flag-picker-swatch flag-colour-${colour} is-selected` : `flag-picker-swatch flag-colour-${colour}`}
      onClick={onSelect}
      disabled={disabled}
    />
  );
}
