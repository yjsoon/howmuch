export const FALLBACK_ACCOUNT_ICON = "🏦";

export const DEFAULT_ICON_BY_ACCOUNT_TYPE: Record<string, string> = {
  checking: "🏦",
  savings: "💰",
  cash: "💵",
  creditCard: "💳",
  lineOfCredit: "💳",
  otherAsset: "📈",
  otherLiability: "📉",
  mortgage: "🏠",
  autoLoan: "🚗",
  studentLoan: "🎓",
  medicalDebt: "🏥",
  otherLoan: "📄",
};

export type AccountPresentation = {
  icon: string;
  name: string;
};

const graphemeSegmenter = new Intl.Segmenter("en", { granularity: "grapheme" });

export function graphemes(value: string): string[] {
  return [...graphemeSegmenter.segment(value)].map((part) => part.segment);
}

export function isAccountIcon(value: string): boolean {
  return parseAccountIcon(value) !== null;
}

/** A single emoji grapheme. */
export function parseAccountIcon(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  const parts = graphemes(trimmed);
  if (parts.length !== 1) return null;
  return isEmojiGrapheme(parts[0]!) ? parts[0]! : null;
}

export function defaultIconForAccountType(type?: string | null): string {
  return (type && DEFAULT_ICON_BY_ACCOUNT_TYPE[type]) || FALLBACK_ACCOUNT_ICON;
}

export function splitLegacyAccountName(name: string): { icon: string | null; name: string } {
  const trimmed = name.trim();
  const parts = graphemes(trimmed);
  if (parts.length === 0) return { icon: null, name: trimmed };
  if (isEmojiGrapheme(parts[0]!)) {
    const rest = parts.slice(1).join("").trim();
    return { icon: parts[0]!, name: rest || trimmed };
  }
  return { icon: null, name: trimmed };
}

/**
 * Icon is a first-class field. A supplied icon wins, then a stored custom
 * icon, then a leading emoji still sitting on the name. Trailing emojis stay
 * on the name. A stored type-default does not block lifting a leftover
 * leading name emoji, so VS16 names missed by SQL still resolve correctly.
 */
export function resolveAccountPresentation(input: {
  name?: string | null;
  icon?: string | null;
  type?: string | null;
  existingIcon?: string | null;
}): AccountPresentation {
  const rawName = String(input.name ?? "").trim() || "Account";
  const split = splitLegacyAccountName(rawName);
  const typeDefault = defaultIconForAccountType(input.type);
  const stored = parseAccountIcon(input.existingIcon);
  const storedBlocksNameEmoji = stored != null && !(split.icon && stored === typeDefault && split.icon !== stored);
  return {
    icon: parseAccountIcon(input.icon)
      ?? (storedBlocksNameEmoji ? stored : null)
      ?? split.icon
      ?? typeDefault,
    name: split.name,
  };
}

const KEYCAP_GRAPHEME = /^(?:[#*]|\d)\u{FE0F}?\u{20E3}$/u;

function isKeycapGrapheme(value: string): boolean {
  return KEYCAP_GRAPHEME.test(value);
}

function isEmojiGrapheme(value: string): boolean {
  if (isKeycapGrapheme(value)) return true;
  return /\p{Extended_Pictographic}/u.test(value) || /\p{Emoji_Presentation}/u.test(value);
}
