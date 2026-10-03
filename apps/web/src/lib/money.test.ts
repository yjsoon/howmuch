import { describe, expect, test } from "bun:test";
import { formatMilliunitsInput, formatSavingsRate, parseMilliunits } from "./money";

describe("parseMilliunits", () => {
  test("parses whole numbers and up to three decimal places exactly", () => {
    expect(parseMilliunits("12")).toBe(12_000);
    expect(parseMilliunits("12.3")).toBe(12_300);
    expect(parseMilliunits("12.34")).toBe(12_340);
    expect(parseMilliunits("12.345")).toBe(12_345);
    expect(parseMilliunits("-0.29")).toBe(-290);
    expect(parseMilliunits(".5")).toBe(500);
    expect(parseMilliunits("-.29")).toBe(-290);
    expect(parseMilliunits("1.")).toBe(1_000);
    expect(parseMilliunits("+1.135")).toBe(1_135);
    expect(parseMilliunits("1,200.50")).toBe(1_200_500);
    expect(parseMilliunits("1,200")).toBe(1_200_000);
  });

  test("rejects scientific notation, extra decimals, and empty values", () => {
    expect(parseMilliunits("")).toBeNull();
    expect(parseMilliunits(".")).toBeNull();
    expect(parseMilliunits("1.2345")).toBeNull();
    expect(parseMilliunits("1e3")).toBeNull();
    expect(parseMilliunits("12.34.5")).toBeNull();
  });
});

describe("formatMilliunitsInput", () => {
  test("round-trips integer milliunits without float residue", () => {
    expect(formatMilliunitsInput(12_345)).toBe("12.345");
    expect(formatMilliunitsInput(-290)).toBe("-0.29");
    expect(formatMilliunitsInput(1_000)).toBe("1");
    expect(parseMilliunits(formatMilliunitsInput(1_135))).toBe(1_135);
  });
});

describe("formatSavingsRate", () => {
  // Demo YTD is ~80% saved. Zero income and rates below -100% (e.g. $26.40 in /
  // $525.31 out) are the cases the Income page recipe never exercises.
  test("dashes zero income and rates below -100 percent, keeps ordinary negatives", () => {
    expect(formatSavingsRate(1_750_000, 8_200_000)).toBe("21.3%");
    expect(formatSavingsRate(-450_000, 3_630_000)).toBe("−12.4%");
    expect(formatSavingsRate(-100, 0)).toBe("—");
    expect(formatSavingsRate(-100, 100)).toBe("−100.0%");
    expect(formatSavingsRate(-101, 100)).toBe("—");
    expect(formatSavingsRate(26_400 - 525_310, 26_400)).toBe("—");
  });
});
