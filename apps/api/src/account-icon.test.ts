import { describe, expect, test } from "bun:test";
import { parseAccountIcon } from "./account-icon";

describe("parseAccountIcon", () => {
  test("accepts a single emoji grapheme", () => {
    expect(parseAccountIcon("💳")).toBe("💳");
    expect(parseAccountIcon(" 🏦 ")).toBe("🏦");
    expect(parseAccountIcon("👩‍💻")).toBe("👩‍💻");
  });

  test("accepts letter-like emoji", () => {
    expect(parseAccountIcon("ℹ️")).toBe("ℹ️");
    expect(parseAccountIcon("Ⓜ️")).toBe("Ⓜ️");
  });

  test("accepts emoji keycaps", () => {
    expect(parseAccountIcon("1️⃣")).toBe("1️⃣");
    expect(parseAccountIcon("0️⃣")).toBe("0️⃣");
    expect(parseAccountIcon("9️⃣")).toBe("9️⃣");
    expect(parseAccountIcon("#️⃣")).toBe("#️⃣");
    expect(parseAccountIcon("*️⃣")).toBe("*️⃣");
    expect(parseAccountIcon("1\u{20E3}")).toBe("1\u{20E3}");
    expect(parseAccountIcon("🔟")).toBe("🔟");
  });

  test("rejects empty, multi-grapheme, and non-emoji values", () => {
    expect(parseAccountIcon("")).toBeNull();
    expect(parseAccountIcon("OCBC")).toBeNull();
    expect(parseAccountIcon("💳💳")).toBeNull();
    expect(parseAccountIcon("4")).toBeNull();
    expect(parseAccountIcon("1")).toBeNull();
    expect(parseAccountIcon("#")).toBeNull();
    expect(parseAccountIcon("*")).toBeNull();
    expect(parseAccountIcon(null)).toBeNull();
  });
});
