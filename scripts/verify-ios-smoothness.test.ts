import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const register = readFileSync(new URL("../apps/ios/HowMuch/Views/RegisterView.swift", import.meta.url), "utf8");
const review = readFileSync(new URL("../apps/ios/HowMuch/Views/AddTransactionsView.swift", import.meta.url), "utf8");

test("register consumers share one filtered snapshot per render", () => {
  for (const property of ["visibleTransactions", "visiblePendingRows", "visibleSchedules"]) {
    // One declaration and one snapshot input, not another search per consumer.
    expect(register.match(new RegExp(`\\b${property}\\b`, "g"))?.length).toBe(2);
  }
  expect(register).toContain("let snapshot = RegisterSnapshot(");
  expect(register).toContain("ForEach(snapshot.currentDateSections)");
  expect(register).toContain("ForEach(snapshot.disclosureDateSections)");
});

test("conversation capture lazily renders the transcript and one keyboard-safe dock", () => {
  expect(review).toContain("LazyVStack(alignment: .leading, spacing: 20)");
  expect(review).toContain("ForEach(session.messages)");
  expect(review).toContain("ScrollViewReader");
  expect(review).not.toContain("Array(items.enumerated())");
  expect(review).not.toContain("Array(session.currentDrafts.enumerated())");
  expect(review).toContain(".safeAreaInset(edge: .bottom)");
  expect(review).not.toContain(".overlay(alignment: .bottomTrailing)");
  expect(review).toContain("CaptureComposerDock");
  expect(review).not.toContain("composerChrome");
  expect(review).not.toContain("session.saveTitle");
  expect(review).not.toContain("Picker(\"Entry mode\"");
  expect(review).toContain("PasteButton(");
  expect(review).toContain("supportedContentTypes:");
  expect(review.match(/PasteButton\(/g)?.length).toBe(1);
  expect(review).not.toContain("CapturePasteControl");
  expect(review).not.toContain("UIPasteControl");
});
