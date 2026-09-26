/**
 * Payee names as banks print them are full of noise: reference codes, card
 * numbers, payment rails ("NETS QR", "PayNow"), processor prefixes ("SQ *",
 * "KrisPay*"), company suffixes, branches and places, often truncated. These
 * helpers reduce a name to its merchant words so that "GRAB*A-5X7K9 SINGAPORE
 * SG" and "Grab" can be recognised as the same merchant.
 */

/** Words that identify a rail, processor, legal form or place rather than a merchant. */
const NOISE_WORDS = new Set([
  // Payment rails and statement boilerplate
  "pos", "nets", "qr", "fast", "payment", "payments", "pay", "paynow", "mobile", "via", "to", "from", "othr", "trf",
  "transfer", "ibg", "giro", "bill", "bills", "debit", "credit", "card", "visa", "mastercard", "amex", "purchase",
  "ref", "inv", "invoice", "online", "ecom", "recurring", "contactless", "wallet",
  // Processor and wallet prefixes
  "sq", "tst", "paypal", "stripe", "sumup", "zettle", "adyen", "ipay", "eghl", "mktp", "mp", "krispay", "globale",
  // Legal forms (Singapore and Malaysia) and web boilerplate
  "pte", "ltd", "limited", "inc", "llc", "corp", "co", "company", "group", "holdings", "the", "and", "sdn", "bhd",
  "restoran", "kedai", "www", "com", "net", "org", "http", "https",
  // Places that appear on almost every local or cross-border statement line
  "sg", "sgp", "sin", "singapore", "spore", "intl", "international", "malaysia", "mys", "johor", "bahru",
]);

const DIGIT_WORDS = ["", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"];

/** Merchant words of a payee name, in order, lowercase. */
export function payeeTokens(name: string | null | undefined): string[] {
  if (!name) return [];
  const chunks = name
    .replace(/&(amp|#38);/gi, "&")
    .replace(/&(#39|apos|rsquo);/gi, "'")
    .replace(/&[a-z]+;|&#\d+;/gi, " ")
    // PayNow payees: "TAN AH KOW (Mobile ending 1234)".
    .replace(/\(\s*mobile ending\s*\d*\s*\)/gi, " ")
    // A place glued onto a truncated name: "Parka ServiSINGAPORE".
    .replace(/([a-z])([A-Z]{4,})(?=[^A-Za-z]|$)/g, "$1 $2")
    .normalize("NFKD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    // One chain, three spellings: "7-11", "7-Eleven", "7 ELEVEN-SENGKANG".
    .replace(/\b7\s*-?\s*(?:11|eleven)\b/g, "seveneleven")
    .replace(/['’`]/g, "")
    .split(/[^a-z0-9]+/)
    .filter(Boolean)
    // "4FINGERS" is "Four Fingers"; longer numbers stay codes.
    .flatMap((chunk) => /^[1-9][a-z]{3,}$/.test(chunk) ? [DIGIT_WORDS[Number(chunk[0])], chunk.slice(1)] : [chunk]);
  // Anything else with a digit is a code, card number, date, store number or phone number.
  const words = chunks.filter((chunk) => !/\d/.test(chunk) && chunk.length >= 3 && !looksLikeCode(chunk));
  const merchant = words.filter((word) => !NOISE_WORDS.has(word));
  // A payee that is only noise ("PayPal") keeps its leading word rather than nothing.
  return merchant.length > 0 ? merchant : words.slice(0, 1);
}

/** Letter-only codes: long runs without vowels, such as "bxkqr". Short ones ("KTMB", "KKH") are real names. */
function looksLikeCode(word: string): boolean {
  return word.length >= 5 && !/[aeiouy]/.test(word);
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
 * How closely two payee names' merchant words match, from 0 to 1. Symmetric:
 * the average of how well each name's words are covered by the other's, so a
 * branch-laden "7 ELEVEN-ONE NORTH MRT" still scores well against a plain
 * "7-Eleven", while "FairPrice Group Hawker" scores below "FairPrice App".
 */
export function nameSimilarity(a: readonly string[], b: readonly string[]): number {
  return (coverage(a, b) + coverage(b, a)) / 2;
}

/**
 * How well `target`'s words are covered by `candidate`'s.
 *
 * The first word is usually the merchant and later words branches or places,
 * so the two first words must match for any coverage at all ("Sushiro" is not
 * "Genki Sushi"), and the first word carries double weight. An exact word match
 * scores fully; one word merely starting with the other scores half, since
 * "Grabfood" and "Grab" are related but not the same thing to budget.
 *
 * Names that run together or split differently ("DIANXIAOERGROUPPTELTD" and
 * "Dian Xiao Er", "fp*Food Panda" and "Foodpanda") have first words that do not
 * line up, so those are also compared joined up: one starting with the other
 * scores 0.9, or 1 when identical. When the first words already match exactly,
 * word boundaries are real and the joined form adds nothing.
 */
function coverage(target: readonly string[], candidate: readonly string[]): number {
  if (target.length === 0 || candidate.length === 0) return 0;
  const first = wordScore(target[0], candidate[0]);
  let joined = 0;
  if (first < 1) {
    const targetJoined = target.join("");
    const candidateJoined = candidate.join("");
    if (targetJoined === candidateJoined) return 1;
    const shorter = Math.min(targetJoined.length, candidateJoined.length);
    if (shorter >= 6 && (targetJoined.startsWith(candidateJoined) || candidateJoined.startsWith(targetJoined))) joined = 0.9;
  }
  if (first === 0) return joined;
  let matched = 2 * first;
  let total = 2;
  for (const word of target.slice(1)) {
    total += 1;
    matched += Math.max(0, ...candidate.map((other) => wordScore(word, other)));
  }
  return Math.max(joined, matched / total);
}

function wordScore(a: string, b: string): number {
  if (a === b) return 1;
  const [short, long] = a.length <= b.length ? [a, b] : [b, a];
  return short.length >= 4 && long.startsWith(short) ? 0.5 : 0;
}
