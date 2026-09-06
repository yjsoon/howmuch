import { describe, expect, test } from "bun:test";
import {
  DEFAULT_MONEY_FORMAT,
  matchesRegisterQuery,
  parseRegisterQuery,
  transactionSearchSql,
  type SearchableFields,
} from "./index";

const fairPrice: SearchableFields = {
  payeeName: "FairPrice Finest",
  memo: "weekly shop",
  categoryName: "Groceries",
  accountName: "Everyday Account",
  amountMilli: -142300,
};

const scoot: SearchableFields = {
  payeeName: "Scoot",
  amountMilli: -12000,
  accountName: "Travel Card",
};

const twelveHundred: SearchableFields = {
  payeeName: "Big Shop",
  amountMilli: -120000,
};

describe("parseRegisterQuery", () => {
  test("returns null for blank input", () => {
    expect(parseRegisterQuery("  ")).toBeNull();
  });

  test("parses typed money precision into a milliunit range", () => {
    expect(parseRegisterQuery("142", DEFAULT_MONEY_FORMAT)?.amount).toEqual({
      lo: 142000,
      hi: 143000,
      sign: "any",
    });
    expect(parseRegisterQuery("142.30", DEFAULT_MONEY_FORMAT)?.amount).toEqual({
      lo: 142300,
      hi: 142310,
      sign: "any",
    });
    expect(parseRegisterQuery("$142.30", DEFAULT_MONEY_FORMAT)?.amount).toEqual({
      lo: 142300,
      hi: 142310,
      sign: "any",
    });
    expect(parseRegisterQuery("-142.30", DEFAULT_MONEY_FORMAT)?.amount?.sign).toBe("outflow");
    expect(parseRegisterQuery("+$12", DEFAULT_MONEY_FORMAT)?.amount).toEqual({
      lo: 12000,
      hi: 13000,
      sign: "inflow",
    });
  });
});

describe("matchesRegisterQuery", () => {
  test("matches FairPrice by payee and by displayed amount spellings", () => {
    for (const raw of ["FairPrice", "142.30", "142", "$142.30"]) {
      const query = parseRegisterQuery(raw, DEFAULT_MONEY_FORMAT);
      expect(query).not.toBeNull();
      expect(matchesRegisterQuery(query!, fairPrice)).toBe(true);
    }
  });

  test("does not treat milliunit digit strings as text", () => {
    const twelve = parseRegisterQuery("12", DEFAULT_MONEY_FORMAT)!;
    expect(matchesRegisterQuery(twelve, fairPrice)).toBe(false);
    expect(matchesRegisterQuery(twelve, twelveHundred)).toBe(false);
    expect(matchesRegisterQuery(twelve, scoot)).toBe(true);
  });

  test("matches split-line payee, memo, category, or amount", () => {
    const split: SearchableFields = {
      payeeName: "Split dinner",
      amountMilli: -50000,
      lines: [
        { payeeName: "Candlenut", amountMilli: -142300, categoryName: "Dining Out", memo: "share" },
        { amountMilli: -35700, categoryName: "Groceries" },
      ],
    };
    expect(matchesRegisterQuery(parseRegisterQuery("Candlenut")!, split)).toBe(true);
    expect(matchesRegisterQuery(parseRegisterQuery("142.30")!, split)).toBe(true);
    expect(matchesRegisterQuery(parseRegisterQuery("share")!, split)).toBe(true);
  });
});

describe("transactionSearchSql", () => {
  test("binds the lowered text needle and amount bounds", () => {
    const query = parseRegisterQuery("142.30")!;
    const sql = transactionSearchSql(query);
    expect(sql.sql).toContain("abs(t.amount_milli) >= ?");
    expect(sql.params).toContain("142.30");
    expect(sql.params).toContain(142300);
    expect(sql.params).toContain(142310);
  });
});
