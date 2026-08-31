import { describe, expect, test } from "bun:test";
import { formatMilliunitsInput, parseMilliunits } from "./money";

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
