import { useMemo, useRef, useState } from "react";
import { Link } from "react-router-dom";
import type { Account, Payee } from "../api/types";

interface Option {
  value: string;
  group: "transfers" | "payees";
}

/**
 * YNAB-style payee dropdown: "Payments and transfers" first (transfer
 * targets for the current account), then saved payees filtered as you type.
 * Free text is always allowed for new payees.
 */
export function PayeeCombobox({
  value,
  onChange,
  accounts,
  currentAccountId,
  payees,
  disabled,
  placeholder,
  autoFocus,
  inputRef,
}: {
  value: string;
  onChange: (value: string) => void;
  accounts: Account[];
  currentAccountId: string;
  payees: Payee[];
  disabled?: boolean;
  placeholder?: string;
  autoFocus?: boolean;
  inputRef?: React.RefObject<HTMLInputElement | null>;
}) {
  const [open, setOpen] = useState(false);
  const [highlight, setHighlight] = useState(-1);
  const fallbackRef = useRef<HTMLInputElement>(null);
  const ref = inputRef ?? fallbackRef;

  const options = useMemo<Option[]>(() => {
    const needle = value.trim().toLowerCase();
    const transfers = accounts
      .filter((account) => !account.closed && account.id !== currentAccountId)
      .map((account) => ({ value: `Transfer : ${account.name}`, group: "transfers" as const }));
    const saved = payees
      .filter((payee) => !payee.deleted && !/^Transfer\s*:/i.test(payee.name))
      .map((payee) => ({ value: payee.name, group: "payees" as const }));
    const all = [...transfers, ...saved];
    if (!needle) {
      return all;
    }
    // Keep the exact current text matchable while narrowing the list.
    return all.filter((option) => option.value.toLowerCase().includes(needle));
  }, [accounts, currentAccountId, payees, value]);

  const select = (option: Option) => {
    onChange(option.value);
    setOpen(false);
    setHighlight(-1);
    ref.current?.focus();
  };

  const onKeyDown = (event: React.KeyboardEvent) => {
    if (event.key === "ArrowDown") {
      event.preventDefault();
      setOpen(true);
      setHighlight((index) => Math.min(index + 1, options.length - 1));
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      setHighlight((index) => Math.max(index - 1, 0));
    } else if (event.key === "Enter") {
      if (open && highlight >= 0 && options[highlight]) {
        event.preventDefault();
        select(options[highlight]);
      } else {
        setOpen(false);
      }
    } else if (event.key === "Escape" || event.key === "Tab") {
      setOpen(false);
      setHighlight(-1);
    }
  };

  let lastGroup: Option["group"] | undefined;

  return (
    <div className="payee-combobox">
      <input
        value={value}
        onChange={(event) => {
          onChange(event.target.value);
          setOpen(true);
          setHighlight(-1);
        }}
        onFocus={() => setOpen(true)}
        onBlur={() => {
          // Option mousedown fires before blur, so selection still lands.
          setOpen(false);
          setHighlight(-1);
        }}
        onKeyDown={onKeyDown}
        disabled={disabled}
        placeholder={placeholder}
        autoFocus={autoFocus}
        ref={ref}
        role="combobox"
        aria-expanded={open}
        aria-autocomplete="list"
        autoComplete="off"
      />
      {open && !disabled && (
        <div className="multi-select-menu payee-menu" role="listbox" aria-label="Payees">
          {options.map((option, index) => {
            const heading = option.group !== lastGroup;
            lastGroup = option.group;
            return (
              <div key={`${option.group}-${option.value}`}>
                {heading && (
                  <div className="menu-divider">
                    {option.group === "transfers" ? "Payments and transfers" : "Saved payees"}
                  </div>
                )}
                <button
                  type="button"
                  className={index === highlight ? "menu-option payee-option payee-option-active" : "menu-option payee-option"}
                  onMouseDown={(event) => {
                    event.preventDefault();
                    select(option);
                  }}
                  onMouseEnter={() => setHighlight(index)}
                >
                  {option.value}
                </button>
              </div>
            );
          })}
          {options.length === 0 && (
            <div className="menu-empty">{value.trim() ? `Save new payee “${value.trim()}”` : "No payees yet."}</div>
          )}
          <Link
            to="/manage?section=payees"
            className="menu-footer-link"
            onMouseDown={(event) => event.stopPropagation()}
          >
            Manage payees
          </Link>
        </div>
      )}
    </div>
  );
}
