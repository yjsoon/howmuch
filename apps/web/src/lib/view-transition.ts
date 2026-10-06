import { flushSync } from "react-dom";

// Updates waiting for the running transition's callback. Between
// startViewTransition and its callback (at least a frame, while the old
// snapshot is captured) a later update must not run first and then be
// overwritten, so it joins this queue and runs after the earlier ones.
let pending: Array<() => void> | null = null;

/**
 * Runs `update` inside a same-document view transition when the browser
 * supports it and the viewer has not asked for reduced motion. While it runs,
 * `<html data-vt="board|theme">` scopes the transition-only CSS (motion.css,
 * rewards-board.css). Updates always apply in call order. Never wrap register
 * row edits or compose state in this.
 */
export function withViewTransition(kind: "board" | "theme", update: () => void): void {
  if (pending) {
    pending.push(update);
    return;
  }
  const root = document.documentElement;
  const reduce = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
  if (reduce || !("startViewTransition" in document) || root.dataset.vt) {
    update();
    return;
  }
  const queue = [update];
  pending = queue;
  const run = () => {
    pending = null;
    flushSync(() => queue.forEach((fn) => fn()));
  };
  root.dataset.vt = kind;
  try {
    document.startViewTransition(run).finished.finally(() => {
      delete root.dataset.vt;
    });
  } catch {
    delete root.dataset.vt;
    if (pending === queue) run();
  }
}
