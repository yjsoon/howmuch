/**
 * Payee names as banks print them are full of noise: reference codes, card
 * numbers, payment rails ("NETS QR", "PayNow"), processor prefixes ("SQ *",
 * "PAYPAL *"), company suffixes and locations. These helpers reduce a name to
 * its merchant words so that "GRAB*A-5X7K9 SINGAPORE SG" and "Grab" can be
 * recognised as the same merchant.
 */

/** Words that identify a rail, processor, legal form or place rather than a merchant. */
const NOISE_WORDS = new Set([
  // Payment rails and statement boilerplate
  "pos", "nets", "qr", "fast", "payment", "payments", "pay", "paynow", "mobile", "via", "to", "from", "othr", "trf",
  "transfer", "ibg", "giro", "bill", "bills", "debit", "credit", "card", "visa", "mastercard", "amex", "purchase",
  "ref", "inv", "invoice", "online", "ecom", "recurring", "contactless", "wallet",
  // Processor prefixes
  "sq", "tst", "paypal", "stripe", "sumup", "zettle", "adyen", "ipay", "eghl", "mktp", "mp",
  // Legal forms and web boilerplate
  "pte", "ltd", "limited", "inc", "llc", "corp", "co", "company", "group", "holdings", "the", "and",
  "www", "com", "net", "org", "http", "https",
  // Places that appear on almost every local statement line
  "sg", "sgp", "sin", "singapore", "spore", "intl", "international",
]);

/** Merchant words of a payee name, in order, lowercase. */
export function payeeTokens(name: string | null | undefined): string[] {
  if (!name) return [];
  const chunks = name
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/['\u2019`]/g, "")
    .split(/[^a-z0-9]+/)
    .filter(Boolean);
  // Anything with a digit is a code, card number, date, store number or phone number.
  const words = chunks.filter((chunk) => !/\d/.test(chunk) && chunk.length >= 3 && !looksLikeCode(chunk));
  const merchant = words.filter((word) => !NOISE_WORDS.has(word));
  // A payee that is only noise ("PayPal") keeps its leading word rather than nothing.
  return merchant.length > 0 ? merchant : words.slice(0, 1);
}

/** Letter-only codes: long runs without vowels, such as "bxkqr" or "hjkl". */
function looksLikeCode(word: string): boolean {
  return word.length >= 4 && !/[aeiouy]/.test(word);
}

/**
 * Short stem of the first merchant word, for a substring search wide enough to
 * catch other spellings ("grabfood" searches "grab", finding "Grab" too).
 * Ranking by `nameSimilarity` then discards what the wide search over-matches.
 */
export function payeeSearchStem(tokens: readonly string[]): string | null {
  const first = tokens[0];
  if (!first) return null;
  return first.slice(0, 4);
}

/**
 * How closely a past name's merchant words match a new one's, from 0 to 1.
 * The first word is usually the merchant and later words are usually branches
 * or places, so the first word must match for any similarity at all, and it
 * carries double weight in the score. Words match when equal, or when
 * one starts with the other and they share at least four letters
 * ("grab"/"grabfood", "mcdonald"/"mcdonalds").
 */
export function nameSimilarity(target: readonly string[], candidate: readonly string[]): number {
  if (target.length === 0 || candidate.length === 0) return 0;
  if (!candidate.some((other) => wordsMatch(target[0], other))) return 0;
  let matched = 0;
  let total = 0;
  target.forEach((word, index) => {
    const weight = index === 0 ? 2 : 1;
    total += weight;
    if (candidate.some((other) => wordsMatch(word, other))) matched += weight;
  });
  return matched / total;
}

function wordsMatch(a: string, b: string): boolean {
  if (a === b) return true;
  const [short, long] = a.length <= b.length ? [a, b] : [b, a];
  return short.length >= 4 && long.startsWith(short);
}
