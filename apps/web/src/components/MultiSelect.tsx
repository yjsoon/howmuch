import { useEffect, useRef, useState } from "react";

export interface MultiSelectOption {
  id: string;
  label: string;
  group?: string;
}

interface Props {
  label: string;
  options: MultiSelectOption[];
  selected: string[];
  onChange: (ids: string[]) => void;
}

/** Compact dropdown multi-select; the trigger summarises the selection. */
export function MultiSelect({ label, options, selected, onChange }: Props) {
  const [open, setOpen] = useState(false);
  const rootRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) {
      return;
    }
    const onClick = (event: MouseEvent) => {
      if (!rootRef.current?.contains(event.target as Node)) {
        setOpen(false);
      }
    };
    document.addEventListener("mousedown", onClick);
    return () => document.removeEventListener("mousedown", onClick);
  }, [open]);

  const summary =
    selected.length === 0
      ? `All ${label.toLowerCase()}`
      : selected.length === 1
        ? (options.find((option) => option.id === selected[0])?.label ?? "1 selected")
        : `${selected.length} ${label.toLowerCase()}`;

  const toggle = (id: string) => {
    onChange(selected.includes(id) ? selected.filter((item) => item !== id) : [...selected, id]);
  };

  let lastGroup: string | undefined;

  return (
    <div className="multi-select" ref={rootRef}>
      <button
        type="button"
        className={selected.length ? "filter-trigger filter-trigger-set" : "filter-trigger"}
        onClick={() => setOpen((value) => !value)}
      >
        {summary} <span className="caret">▾</span>
      </button>
      {open && (
        <div className="multi-select-menu" role="listbox" aria-label={label}>
          {selected.length > 0 && (
            <button type="button" className="menu-clear" onClick={() => onChange([])}>
              Clear selection
            </button>
          )}
          {options.map((option) => {
            const heading = option.group !== lastGroup ? option.group : undefined;
            lastGroup = option.group;
            return (
              <div key={option.id}>
                {heading && <div className="menu-group">{heading}</div>}
                <label className="menu-option">
                  <input
                    type="checkbox"
                    checked={selected.includes(option.id)}
                    onChange={() => toggle(option.id)}
                  />
                  {option.label}
                </label>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
