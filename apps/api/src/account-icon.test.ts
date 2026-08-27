import { describe, expect, test } from "bun:test";
import {
  defaultIconForAccountType,
  parseAccountIcon,
  resolveAccountPresentation,
  splitLegacyAccountName,
} from "./account-icon";

describe("parseAccountIcon", () => {
  test("accepts a single emoji grapheme", () => {
    expect(parseAccountIcon("💳")).toBe("💳");
    expect(parseAccountIcon(" 🏦 ")).toBe("🏦");
    expect(parseAccountIcon("👩‍💻")).toBe("👩‍💻");
  });

  test("rejects empty, multi-grapheme, and non-emoji values", () => {
    expect(parseAccountIcon("")).toBeNull();
    expect(parseAccountIcon("OCBC")).toBeNull();
    expect(parseAccountIcon("💳💳")).toBeNull();
    expect(parseAccountIcon("4")).toBeNull();
    expect(parseAccountIcon(null)).toBeNull();
  });
});

describe("splitLegacyAccountName", () => {
  test("lifts a leading emoji and leaves the rest as the name", () => {
    expect(splitLegacyAccountName("💳 OCBC 365")).toEqual({ icon: "💳", name: "OCBC 365" });
    expect(splitLegacyAccountName("💳OCBC")).toEqual({ icon: "💳", name: "OCBC" });
  });

  test("lifts a trailing emoji when the name does not start with one", () => {
    expect(splitLegacyAccountName("Travel ✈️")).toEqual({ icon: "✈️", name: "Travel" });
  });

  test("keeps a name that is only an emoji", () => {
    expect(splitLegacyAccountName("💳")).toEqual({ icon: "💳", name: "💳" });
  });

  test("leaves plain names alone", () => {
    expect(splitLegacyAccountName("Everyday Account")).toEqual({ icon: null, name: "Everyday Account" });
  });
});

describe("resolveAccountPresentation", () => {
  test("prefers an explicit icon over a stored icon or a name emoji", () => {
    expect(resolveAccountPresentation({
      name: "💳 OCBC",
      icon: "🐷",
      existingIcon: "🏦",
      type: "checking",
    })).toEqual({ icon: "🐷", name: "OCBC" });
  });

  test("keeps a stored icon when a later import still has an emoji on the name", () => {
    expect(resolveAccountPresentation({
      name: "💳 OCBC",
      existingIcon: "🐷",
      type: "creditCard",
    })).toEqual({ icon: "🐷", name: "OCBC" });
  });

  test("uses a name emoji when the account has no stored icon", () => {
    expect(resolveAccountPresentation({ name: "💰 Rainy Day", type: "savings" }))
      .toEqual({ icon: "💰", name: "Rainy Day" });
  });

  test("lifts a leftover name emoji over a stored type-default icon", () => {
    expect(resolveAccountPresentation({
      name: "Travel ✈️",
      existingIcon: "💳",
      type: "creditCard",
    })).toEqual({ icon: "✈️", name: "Travel" });
  });

  test("falls back to the account type", () => {
    expect(resolveAccountPresentation({ name: "Visa", type: "creditCard" }))
      .toEqual({ icon: "💳", name: "Visa" });
    expect(defaultIconForAccountType("checking")).toBe("🏦");
  });
});
