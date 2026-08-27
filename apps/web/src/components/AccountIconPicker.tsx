import { useEffect, useId, useRef, useState } from "react";
import { ACCOUNT_ICON_PALETTE, accountIcon, parseAccountIconInput } from "../lib/account-icon";

export function AccountIconButton({
  accountName,
  icon,
  disabled,
  onChange,
}: {
  accountName: string;
  icon: string;
  disabled?: boolean;
  onChange: (icon: string) => Promise<void> | void;
}) {
  const [open, setOpen] = useState(false);
  const [custom, setCustom] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const rootRef = useRef<HTMLDivElement>(null);
  const labelId = useId();

  useEffect(() => {
    if (!open) return;
    const onPointerDown = (event: PointerEvent) => {
      if (!rootRef.current?.contains(event.target as Node)) setOpen(false);
    };
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") setOpen(false);
    };
    document.addEventListener("pointerdown", onPointerDown);
    document.addEventListener("keydown", onKeyDown);
    return () => {
      document.removeEventListener("pointerdown", onPointerDown);
      document.removeEventListener("keydown", onKeyDown);
    };
  }, [open]);

  const choose = async (next: string) => {
    const parsed = parseAccountIconInput(next);
    if (!parsed) {
      setError("Choose a single emoji.");
      return;
    }
    setSaving(true);
    setError(null);
    try {
      await onChange(parsed);
      setOpen(false);
      setCustom("");
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Could not save that icon.");
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="account-icon-picker" ref={rootRef}>
      <button
        type="button"
        className="account-icon-button"
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-label={`Change icon for ${accountName}`}
        disabled={disabled || saving}
        onClick={(event) => {
          event.preventDefault();
          event.stopPropagation();
          setOpen((current) => !current);
        }}
      >
        <span aria-hidden="true">{accountIcon({ icon })}</span>
      </button>
      {open && (
        <div className="account-icon-popover" role="dialog" aria-labelledby={labelId}>
          <p id={labelId} className="account-icon-popover-title">Choose an icon</p>
          <div className="account-icon-grid">
            {ACCOUNT_ICON_PALETTE.map((candidate) => (
              <button
                key={candidate}
                type="button"
                className={candidate === icon ? "account-icon-choice account-icon-choice-active" : "account-icon-choice"}
                aria-label={`Use ${candidate}`}
                aria-pressed={candidate === icon}
                disabled={saving}
                onClick={() => void choose(candidate)}
              >
                {candidate}
              </button>
            ))}
          </div>
          <label className="account-icon-custom">
            <span>Or type any emoji</span>
            <input
              value={custom}
              onChange={(event) => {
                setCustom(event.target.value);
                setError(null);
              }}
              onKeyDown={(event) => {
                if (event.key === "Enter") {
                  event.preventDefault();
                  void choose(custom);
                }
              }}
              inputMode="text"
              autoComplete="off"
              spellCheck={false}
              disabled={saving}
            />
          </label>
          {error && <p className="account-icon-error">{error}</p>}
        </div>
      )}
    </div>
  );
}
