import { useEffect, useRef, type RefObject } from "react";

/**
 * Dismissal for a small popover or disclosure list, following MultiSelect's
 * pattern: a mousedown outside `root` closes it, and so does Escape, which also
 * returns focus to `trigger` so keyboard users are not dropped on <body>.
 * An outside click leaves focus wherever that click put it. Tabbing out of
 * `root` closes it too, so an open list never lingers over the board.
 */
export function useDismiss(
  open: boolean,
  close: () => void,
  root: RefObject<HTMLElement | null>,
  trigger: RefObject<HTMLElement | null>,
): void {
  const closeRef = useRef(close);
  closeRef.current = close;

  useEffect(() => {
    if (!open) {
      return;
    }
    const element = root.current;
    const onMouseDown = (event: MouseEvent) => {
      if (!element?.contains(event.target as Node)) {
        closeRef.current();
      }
    };
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        closeRef.current();
        trigger.current?.focus();
      }
    };
    const onFocusOut = (event: FocusEvent) => {
      const next = event.relatedTarget;
      if (next instanceof Node && !element?.contains(next)) {
        closeRef.current();
      }
    };
    document.addEventListener("mousedown", onMouseDown);
    document.addEventListener("keydown", onKeyDown);
    element?.addEventListener("focusout", onFocusOut);
    return () => {
      document.removeEventListener("mousedown", onMouseDown);
      document.removeEventListener("keydown", onKeyDown);
      element?.removeEventListener("focusout", onFocusOut);
    };
  }, [open, root, trigger]);
}
