import { expect, test } from "bun:test";
import { nameSimilarity, payeeSearchStem, payeeTokens } from "./payee-names";

test("strips codes, rails, processors and places from bank payee names", () => {
  const cases: Array<[string, string[]]> = [
    ["GRAB*A-5X7K9QWE SINGAPORE SG", ["grab"]],
    ["GRABFOOD*ORDER 8812", ["grabfood", "order"]],
    ["NETS QR KOPITIAM 12345", ["kopitiam"]],
    ["POS 1234 NTUC FP-TAMPINES 1 12/09", ["ntuc", "tampines"]],
    ["SQ *COMMON MAN COFFEE", ["common", "man", "coffee"]],
    ["TST* Common Man Coffee Roasters", ["common", "man", "coffee", "roasters"]],
    ["PAYPAL *NETFLIX 4029357733", ["netflix"]],
    ["AMZN MKTP SG*2K3J45LM1", ["amzn"]],
    ["APPLE.COM/BILL 866-712-7753 IE", ["apple"]],
    ["Mcdonald's-Tampines Mall", ["mcdonalds", "tampines", "mall"]],
    ["Café Nero", ["cafe", "nero"]],
    ["BUS/MRT 123456789 SINGAPORE SG", ["bus", "mrt"]],
    ["FAST PAYMENT via PayNow-Mobile to JOHN TAN OTHR 123456", ["john", "tan"]],
    ["PayPal", ["paypal"]],
    ["1234 5678", []],
  ];
  for (const [name, tokens] of cases) expect([name, payeeTokens(name)]).toEqual([name, tokens]);
  expect(payeeTokens(null)).toEqual([]);
});

test("recognises the same merchant under different spellings", () => {
  const grab = payeeTokens("Grab");
  expect(nameSimilarity(payeeTokens("GRAB*A-5X7K9QWE SINGAPORE SG"), grab)).toBe(1);
  expect(nameSimilarity(payeeTokens("GRABFOOD*ORDER 8812"), grab)).toBeCloseTo(2 / 3);
  expect(nameSimilarity(payeeTokens("NETS QR KOPITIAM 12345"), payeeTokens("Kopitiam @ Bishan"))).toBe(1);
  expect(nameSimilarity(payeeTokens("Mcdonald's-Tampines Mall"), payeeTokens("MCDONALDS JURONG"))).toBe(0.5);
  // A shared branch or place is not the same merchant.
  expect(nameSimilarity(payeeTokens("Mcdonald's-Tampines Mall"), payeeTokens("Tampines Mall Carpark"))).toBe(0);
  expect(nameSimilarity(payeeTokens("NTUC FairPrice"), payeeTokens("Tampines Mall Carpark"))).toBe(0);
  expect(nameSimilarity(payeeTokens("Starbucks Raffles City"), payeeTokens("Raffles Hotel"))).toBe(0);
});

test("searches by a short stem of the merchant word", () => {
  expect(payeeSearchStem(payeeTokens("GRABFOOD*ORDER 8812"))).toBe("grab");
  expect(payeeSearchStem(payeeTokens("NETS QR KOPITIAM 12345"))).toBe("kopi");
  expect(payeeSearchStem([])).toBeNull();
});
