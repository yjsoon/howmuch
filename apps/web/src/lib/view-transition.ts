import { flushSync } from "react-dom";

/**
 * Runs `update` inside a same-document view transition when the browser
 * supports it and the viewer has not asked for reduced motion. While it runs,
 * `<html data-vt="board|theme">` scopes the transition-only CSS (motion.css,
 * rewards-board.css). Never wrap register row edits or compose state in this.
 */
export function withViewTransition(kind: "board" | "theme", update: () => void): void {
  const root = document.documentElement;
  const reduce = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
  if (reduce || !("startViewTransition" in document) || root.dataset.vt) {
    update();
    return;
  }
  root.dataset.vt = kind;
  const transition = document.startViewTransition(() => flushSync(update));
  transition.finished.finally(() => {
    delete root.dataset.vt;
  });
}
