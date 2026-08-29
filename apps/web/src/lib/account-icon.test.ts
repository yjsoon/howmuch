import { describe, expect, test } from "bun:test";
import { parseAccountIconInput } from "./account-icon";

describe("parseAccountIconInput", () => {
  test("accepts letter-like emoji", () => {
    expect(parseAccountIconInput("ℹ️")).toBe("ℹ️");
  });

  test("accepts emoji keycaps", () => {
    expect(parseAccountIconInput("1️⃣")).toBe("1️⃣");
    expect(parseAccountIconInput("#️⃣")).toBe("#️⃣");
    expect(parseAccountIconInput("1\u{20E3}")).toBe("1\u{20E3}");
  });

  test("rejects a bare digit", () => {
    expect(parseAccountIconInput("1")).toBeNull();
    expect(parseAccountIconInput("4")).toBeNull();
  });
});
