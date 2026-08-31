import { useEffect, useRef } from "react";
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

const FLAG_ORDER: readonly string[] = ["", ...FLAG_COLOURS];

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
  const rootRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const root = rootRef.current;
    if (!root || !root.contains(document.activeElement)) {
      return;
    }
    const selected = root.querySelector('[role="radio"][aria-checked="true"]');
    if (selected instanceof HTMLElement) {
      selected.focus();
    }
  }, [value]);

  return (
    <div
      ref={rootRef}
      className="flag-picker"
      role="radiogroup"
      aria-labelledby={labelledBy}
      onKeyDown={(event) => {
        if (disabled) {
          return;
        }
        if (event.key !== "ArrowRight" && event.key !== "ArrowLeft" && event.key !== "ArrowDown" && event.key !== "ArrowUp") {
          return;
        }
        event.preventDefault();
        const from = FLAG_ORDER.indexOf(value);
        const index = from < 0 ? 0 : from;
        const delta = event.key === "ArrowRight" || event.key === "ArrowDown" ? 1 : -1;
        onChange(FLAG_ORDER[(index + delta + FLAG_ORDER.length) % FLAG_ORDER.length] ?? "");
      }}
    >
      <button
        type="button"
        role="radio"
        tabIndex={value ? -1 : 0}
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
      tabIndex={selected ? 0 : -1}
      aria-checked={selected}
      aria-label={flagTitle(colour)}
      className={selected ? `flag-picker-swatch flag-colour-${colour} is-selected` : `flag-picker-swatch flag-colour-${colour}`}
      onClick={onSelect}
      disabled={disabled}
    />
  );
}
