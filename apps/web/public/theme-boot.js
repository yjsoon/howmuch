/* Applies the saved Halation look and colour mode before first paint.
   A separate file because the CSP (public/_headers) only allows script-src 'self'.
   Keep LOOKS in step with src/lib/theme.ts. */
(function () {
  var LOOKS = { "dusk-ridge": ["#2b1f2c", "#120d13"], "ridge-charcoal": ["#242722", "#0b0c0c"], "overexposed": ["#fbf7ef", "#1a1613"] };
  var look = "dusk-ridge", mode = "system";
  try {
    var raw = JSON.parse(localStorage.getItem("howmuch.theme.v1") || "null");
    if (raw && Object.prototype.hasOwnProperty.call(LOOKS, raw.look)) look = raw.look;
    if (raw && (raw.mode === "light" || raw.mode === "dark")) mode = raw.mode;
  } catch (e) { /* storage blocked: defaults */ }
  var dark = mode === "dark" || (mode === "system" && !!window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches);
  var root = document.documentElement;
  root.setAttribute("data-theme", look);
  root.setAttribute("data-mode", dark ? "dark" : "light");
  var meta = document.querySelector('meta[name="theme-color"]');
  if (meta) meta.setAttribute("content", LOOKS[look][dark ? 1 : 0]);
})();
