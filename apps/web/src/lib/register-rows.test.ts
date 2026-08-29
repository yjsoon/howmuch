import { describe, expect, test } from "bun:test";
import {
  applyRegisterPatches,
  deletedIdsForRemoval,
  markDeletedByIds,
  replaceRowById,
  unlinkSplitMirrorParent,
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

  test("unlinkSplitMirrorParent clears the matching split transfer line", () => {
    const groceries = { id: "sub-food", transfer_account_id: null, transfer_transaction_id: null };
    const stash = { id: "sub-stash", transfer_account_id: "saver", transfer_transaction_id: "mirror" };
    const parent = { id: "parent", subtransactions: [groceries, stash] };
    const other = { id: "other", subtransactions: [{ id: "plain" }] };
    expect(unlinkSplitMirrorParent([other, parent], { id: "mirror", parent_transaction_id: "parent" })).toEqual({
      id: "parent",
      subtransactions: [groceries, { id: "sub-stash", transfer_account_id: null, transfer_transaction_id: null }],
    });
    expect(unlinkSplitMirrorParent([parent], { id: "mirror", transfer_transaction_id: "sub-stash" })).toEqual({
      id: "parent",
      subtransactions: [groceries, { id: "sub-stash", transfer_account_id: null, transfer_transaction_id: null }],
    });
    expect(unlinkSplitMirrorParent([parent], { id: "unrelated" })).toBeNull();
  });

  test("deletedIdsForRemoval includes split-line transfer mirrors", () => {
    expect(
      deletedIdsForRemoval({
        id: "parent",
        subtransactions: [
          { transfer_transaction_id: "mirror-a" },
          {},
          { transfer_transaction_id: "mirror-b" },
        ],
      }),
    ).toEqual(["parent", "mirror-a", "mirror-b"]);
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
