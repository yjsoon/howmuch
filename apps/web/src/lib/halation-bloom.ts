/**
 * The save bloom: one colour-only wash across a saved row (motion.css,
 * `tr[data-bloom] > td`). It is a confirmation, so it also runs under reduced
 * motion. Only in-row commits and approvals bloom, never cleared toggles,
 * bulk categorising or compose saves, and never more than MAX_ROWS at once.
 */
const MAX_ROWS = 25;

export function bloom(el: Element | null): void {
  if (!el || el.hasAttribute("data-bloom")) return;
  el.setAttribute("data-bloom", "");
  const clear = () => {
    window.clearTimeout(safety);
    el.removeEventListener("animationend", done);
    el.removeAttribute("data-bloom");
  };
  const done = (event: Event) => {
    if ((event as AnimationEvent).animationName === "hl-bloom") clear();
  };
  el.addEventListener("animationend", done);
  // Safety net: the row unmounted, or animations are not running at all.
  const safety = window.setTimeout(clear, 1000);
}

/** Mirrors registerRowDomId() for posted rows (lib/register-row-edit.ts, which is protected). */
export const postedRowDomId = (id: string) => `register-row-${encodeURIComponent(id)}`;

export function bloomRows(ids: readonly string[]): void {
  for (const id of ids.slice(0, MAX_ROWS)) bloom(document.getElementById(id));
}
