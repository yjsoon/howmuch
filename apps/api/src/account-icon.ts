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

/** A single emoji grapheme, including ZWJ sequences. Rejects letters and digits. */
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
  if (parts.length > 1 && isEmojiGrapheme(parts.at(-1)!)) {
    const rest = parts.slice(0, -1).join("").trim();
    return { icon: parts.at(-1)!, name: rest || trimmed };
  }
  return { icon: null, name: trimmed };
}

/**
 * Icon is a first-class field. A supplied icon wins, then a stored icon,
 * then an emoji still sitting on the name, then the account type.
 */
export function resolveAccountPresentation(input: {
  name?: string | null;
  icon?: string | null;
  type?: string | null;
  existingIcon?: string | null;
}): AccountPresentation {
  const rawName = String(input.name ?? "").trim() || "Account";
  const split = splitLegacyAccountName(rawName);
  return {
    icon: parseAccountIcon(input.icon)
      ?? parseAccountIcon(input.existingIcon)
      ?? split.icon
      ?? defaultIconForAccountType(input.type),
    name: split.name,
  };
}

function isEmojiGrapheme(value: string): boolean {
  if (/\p{L}|\p{Nd}/u.test(value)) return false;
  return /\p{Extended_Pictographic}/u.test(value) || /\p{Emoji_Presentation}/u.test(value);
}
