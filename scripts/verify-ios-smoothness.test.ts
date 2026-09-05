import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const register = readFileSync(new URL("../apps/ios/HowMuch/Views/RegisterView.swift", import.meta.url), "utf8");
const review = readFileSync(new URL("../apps/ios/HowMuch/Views/IntakeReviewListView.swift", import.meta.url), "utf8");

test("register consumers share one filtered snapshot per render", () => {
  for (const property of ["visibleTransactions", "visiblePendingRows", "visibleSchedules"]) {
    // One declaration and one snapshot input, not another search per consumer.
    expect(register.match(new RegExp(`\\b${property}\\b`, "g"))?.length).toBe(2);
  }
  expect(register).toContain("let snapshot = RegisterSnapshot(");
  expect(register).toContain("ForEach(snapshot.currentDateSections)");
  expect(register).toContain("ForEach(snapshot.disclosureDateSections)");
});

test("batch review lazily renders stable rows and reserves space for the add action", () => {
  expect(review).toContain("LazyVStack(spacing: 0)");
  expect(review).toContain("ForEach(items)");
  expect(review).not.toContain("Array(items.enumerated())");
  expect(review).toContain(".safeAreaInset(edge: .bottom, alignment: .trailing)");
  expect(review).not.toContain(".overlay(alignment: .bottomTrailing)");
});
