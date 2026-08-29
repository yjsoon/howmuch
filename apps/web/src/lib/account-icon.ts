export const ACCOUNT_ICON_PALETTE = [
  "🏦", "💳", "💰", "💵", "💸", "🏠", "🚗", "✈️",
  "📈", "📉", "💼", "🛒", "🎓", "🏥", "📱", "💻",
  "⭐", "🌴", "☕", "🍔", "🎮", "🐱", "🐶", "🐷",
] as const;

export function accountIcon(account: { icon?: string | null }): string {
  const icon = account.icon?.trim();
  return icon || "🏦";
}

const KEYCAP_GRAPHEME = /^(?:[#*]|\d)\u{FE0F}?\u{20E3}$/u;

export function parseAccountIconInput(value: string): string | null {
  const trimmed = value.trim();
  const parts = [...new Intl.Segmenter("en", { granularity: "grapheme" }).segment(trimmed)];
  if (parts.length !== 1) return null;
  const grapheme = parts[0]!.segment;
  if (KEYCAP_GRAPHEME.test(grapheme)) return grapheme;
  if (/\p{L}|\p{Nd}/u.test(grapheme)) return null;
  return /\p{Extended_Pictographic}/u.test(grapheme) || /\p{Emoji_Presentation}/u.test(grapheme)
    ? grapheme
    : null;
}
