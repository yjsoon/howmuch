import { useEffect, useRef, useState } from "react";

export interface MultiSelectOption {
  id: string;
  label: string;
  group?: string;
  /** Rendered below a "Rarely used" divider: hidden/bookkeeping categories. */
  muted?: boolean;
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
  const [needle, setNeedle] = useState("");
  const rootRef = useRef<HTMLDivElement>(null);
  const searchRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (!open) {
      setNeedle("");
      return;
    }
    searchRef.current?.focus();
    const onClick = (event: MouseEvent) => {
      if (!rootRef.current?.contains(event.target as Node)) {
        setOpen(false);
      }
    };
    document.addEventListener("mousedown", onClick);
    return () => document.removeEventListener("mousedown", onClick);
  }, [open]);

  useEffect(() => {
    if (!open) {
      return;
    }
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        setOpen(false);
      }
    };
    document.addEventListener("keydown", onKeyDown);
    return () => document.removeEventListener("keydown", onKeyDown);
  }, [open]);

  const summary =
    selected.length === 0
      ? `All ${label.toLowerCase()}`
      : selected.length === 1
        ? (options.find((option) => option.id === selected[0])?.label ?? "1 selected")
        : `${options.find((option) => option.id === selected[0])?.label ?? label} +${selected.length - 1}`;

  const toggle = (id: string) => {
    onChange(selected.includes(id) ? selected.filter((item) => item !== id) : [...selected, id]);
  };

  const searchable = options.length > 12;
  const query = needle.trim().toLowerCase();
  const visible = query
    ? options.filter(
        (option) =>
          option.label.toLowerCase().includes(query) || option.group?.toLowerCase().includes(query),
      )
    : options;

  const toggleGroup = (group: string) => {
    const ids = visible.filter((option) => option.group === group).map((option) => option.id);
    const allSelected = ids.every((id) => selected.includes(id));
    onChange(
      allSelected
        ? selected.filter((id) => !ids.includes(id))
        : [...selected, ...ids.filter((id) => !selected.includes(id))],
    );
  };

  let lastGroup: string | undefined;
  let dividerShown = false;

  return (
    <div className="multi-select" ref={rootRef}>
      <button
        type="button"
        className={selected.length ? "filter-trigger filter-trigger-set" : "filter-trigger"}
        onClick={() => setOpen((value) => !value)}
        aria-expanded={open}
        aria-haspopup="listbox"
      >
        {summary} <span className="caret">▾</span>
      </button>
      {open && (
        <div className="multi-select-menu" role="listbox" aria-label={label}>
          {searchable && (
            <div className="menu-search">
              <input
                type="search"
                placeholder={`Filter ${label.toLowerCase()}…`}
                value={needle}
                onChange={(event) => setNeedle(event.target.value)}
                ref={searchRef}
                aria-label={`Filter ${label.toLowerCase()}`}
              />
            </div>
          )}
          {selected.length > 0 && (
            <button type="button" className="menu-clear" onClick={() => onChange([])}>
              Clear selection
            </button>
          )}
          {visible.map((option) => {
            const divider = option.muted && !dividerShown;
            dividerShown = dividerShown || Boolean(option.muted);
            const heading = option.group !== lastGroup || divider ? option.group : undefined;
            lastGroup = option.group;
            return (
              <div key={option.id}>
                {divider && <div className="menu-divider">Rarely used</div>}
                {heading && (
                  <button type="button" className="menu-group" onClick={() => toggleGroup(heading)}>
                    {heading}
                  </button>
                )}
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
          {visible.length === 0 && <div className="menu-empty">No matches.</div>}
        </div>
      )}
    </div>
  );
}
