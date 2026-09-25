import { expect, test } from "bun:test";
import { nameSimilarity, payeeSearchStem, payeeTokens } from "./payee-names";

// Formats seen on Singapore card, NETS and PayNow statement lines. Merchants are
// public chains; codes, numbers and personal names are made up.
test("strips codes, rails, processors, suffixes and places from bank payee names", () => {
  const cases: Array<[string, string[]]> = [
    ["GRAB*A-5X7K9QWE SINGAPORE SG", ["grab"]],
    ["GRABFOOD*ORDER 8812", ["grabfood", "order"]],
    ["NETS QR KOPITIAM 12345", ["kopitiam"]],
    ["-4821 KOUFU PTE LTD SINGAPORE SG", ["koufu"]],
    ["SQ *COMMON MAN COFFEE", ["common", "man", "coffee"]],
    ["PAYPAL *NETFLIX 4029357733", ["netflix"]],
    ["KrisPay*Tai Cheong", ["tai", "cheong"]],
    ["NET*HOTBAKE 24/7", ["hotbake"]],
    ["APPLE.COM/BILL 866-712-7753 IE", ["apple"]],
    ["Mcdonald's-Tampines Mall", ["mcdonalds", "tampines", "mall"]],
    ["Café Nero", ["cafe", "nero"]],
    ["MERLE &amp; CO SINGAPORE", ["merle"]],
    ["TAN AH KOW (Mobile ending 1234)", ["tan", "kow"]],
    ["GlobalE /Gray Parka ServiSINGAPORE", ["gray", "parka", "servi"]],
    ["NOVOTEL JB - FRONT DESK JOHOR BAHRU", ["novotel", "front", "desk"]],
    ["Swee Yee Food Sdn Bhd", ["swee", "yee", "food"]],
    ["7-11", ["seveneleven"]],
    ["7 ELEVEN-TAMPINES CENTR", ["seveneleven", "tampines", "centr"]],
    ["4FINGERS CRISPY CHICKE", ["four", "fingers", "crispy", "chicke"]],
    ["676 Woodlands Teochew", ["woodlands", "teochew"]],
    ["KTMB", ["ktmb"]],
    ["FAST PAYMENT via PayNow-Mobile to TAN AH KOW OTHR 123456", ["tan", "kow"]],
    ["PayPal", ["paypal"]],
    ["1234 5678", []],
  ];
  for (const [name, tokens] of cases) expect([name, payeeTokens(name)]).toEqual([name, tokens]);
  expect(payeeTokens(null)).toEqual([]);
});

const similarity = (a: string, b: string) => nameSimilarity(payeeTokens(a), payeeTokens(b));

test("recognises one merchant under different spellings, codes and branches", () => {
  expect(similarity("GRAB*A-5X7K9QWE SINGAPORE SG", "Grab")).toBe(1);
  expect(similarity("Grab Malaysia", "Grab")).toBe(1);
  expect(similarity("NETS QR KOPITIAM 12345", "Kopitiam @ Bishan")).toBeCloseTo(0.83, 2);
  expect(similarity("-4821 KOUFU PTE LTD SINGAPORE SG", "Koufu")).toBe(1);
  expect(similarity("7-11", "7-Eleven")).toBe(1);
  expect(similarity("7 ELEVEN-TAMPINES CENTR", "7-Eleven")).toBeGreaterThanOrEqual(0.7);
  expect(similarity("4FINGERS CRISPY CHICKE", "Four Fingers")).toBeCloseTo(0.8);
  expect(similarity("DIANXIAOERGROUPPTELTD +6500000000", "Dian Xiao Er")).toBe(0.9);
  expect(similarity("fp*Food Panda", "Foodpanda subscription")).toBe(0.9);
  expect(similarity("SP DIGITAL PL-UTIL-RE", "SP Digital PL-Utilitie")).toBeCloseTo(0.83, 2);
  expect(similarity("Sheng Siong Supermarke", "Sheng Siong")).toBe(0.875);
});

test("keeps different merchants apart", () => {
  // The merchant word must be first in both: a shared later word is not enough.
  expect(similarity("Sushiro", "Genki Sushi")).toBe(0);
  expect(similarity("Sheng Siong", "Fong Sheng Hao")).toBe(0);
  expect(similarity("Mcdonald's-Tampines Mall", "Tampines Mall Carpark")).toBe(0);
  expect(similarity("Toast Box", "TWENTY LOAF TOASTIES")).toBe(0);
  // Related but budgeted differently: a prefix match counts half.
  expect(similarity("Grabfood", "Grab")).toBe(0.5);
  // A sub-brand keeps a real word boundary, so it scores below the plain name.
  expect(similarity("FairPrice Group Hawker", "FairPrice")).toBeLessThan(similarity("FairPrice", "Fairprice"));
  // Two unrelated PayNow payees no longer match on "mobile ending".
  expect(similarity("TAN AH KOW (Mobile ending 1234)", "LIM BEE LENG (Mobile ending 5678)")).toBe(0);
});

test("searches by a short stem of the merchant word", () => {
  expect(payeeSearchStem(payeeTokens("GRABFOOD*ORDER 8812"))).toBe("grab");
  expect(payeeSearchStem(payeeTokens("NETS QR KOPITIAM 12345"))).toBe("kopi");
  expect(payeeSearchStem([])).toBeNull();
});
