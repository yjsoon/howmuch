import { describe, expect, test } from "bun:test";
import {
  applyRegisterPatches,
  deletedIdsForRemoval,
  markDeletedByIds,
  replaceRowById,
} from "./register-rows";

function row(id: string, deleted = false, cleared = "uncleared") {
  return { id, deleted, cleared };
}

describe("register rows", () => {
  test("replaceRowById swaps the matching row and keeps the rest", () => {
    const next = row("b", false, "cleared");
    expect(replaceRowById([row("a"), row("b"), row("c")], next)).toEqual([
      row("a"),
      next,
      row("c"),
    ]);
  });

  test("deletedIdsForRemoval includes the transfer pair when present", () => {
    expect(deletedIdsForRemoval({ id: "a" })).toEqual(["a"]);
    expect(deletedIdsForRemoval({ id: "a", transfer_transaction_id: "b" })).toEqual(["a", "b"]);
  });

  test("markDeletedByIds flips only the named live rows", () => {
    expect(markDeletedByIds([row("a"), row("b", true), row("c")], new Set(["a", "b"]))).toEqual([
      row("a", true),
      row("b", true),
      row("c"),
    ]);
  });

  test("applyRegisterPatches replaces then marks deleted", () => {
    const replacements = new Map([["b", row("b", false, "cleared")]]);
    expect(applyRegisterPatches([row("a"), row("b"), row("c")], replacements, new Set(["c"]))).toEqual([
      row("a"),
      row("b", false, "cleared"),
      row("c", true),
    ]);
  });
});
