import { describe, expect, test } from "bun:test";
import {
  emptySelection,
  headerState,
  reduceSelection,
  selectedIds,
  type RegisterSelectionRow,
} from "./register-selection";

const SCOPE = "plan|2026-01|2026-08";

function rows(...ids: string[]): RegisterSelectionRow[] {
  return ids.map((id) => ({ id }));
}

describe("register selection", () => {
  test("toggles one row on and off", () => {
    const visible = rows("a", "b", "c");
    const selected = reduceSelection(emptySelection(SCOPE), visible, { kind: "toggle", index: 1 }, SCOPE);
    expect(selectedIds(selected, visible, SCOPE)).toEqual(["b"]);
    expect(headerState(selected, visible, SCOPE)).toBe("some");

    const cleared = reduceSelection(selected, visible, { kind: "toggle", index: 1 }, SCOPE);
    expect(selectedIds(cleared, visible, SCOPE)).toEqual([]);
    expect(headerState(cleared, visible, SCOPE)).toBe("none");
  });

  test("releases rows when a live shift range shrinks", () => {
    const visible = rows("a", "b", "c", "d");
    let selection = reduceSelection(emptySelection(SCOPE), visible, { kind: "toggle", index: 0 }, SCOPE);
    selection = reduceSelection(selection, visible, { kind: "extend", index: 3 }, SCOPE);
    expect(selectedIds(selection, visible, SCOPE)).toEqual(["a", "b", "c", "d"]);

    selection = reduceSelection(selection, visible, { kind: "extend", index: 1 }, SCOPE);
    expect(selectedIds(selection, visible, SCOPE)).toEqual(["a", "b"]);
  });

  test("selects and clears every visible row", () => {
    const visible = rows("a", "b", "c");
    const selection = reduceSelection(emptySelection(SCOPE), visible, { kind: "all" }, SCOPE);
    expect(selectedIds(selection, visible, SCOPE)).toEqual(["a", "b", "c"]);
    expect(headerState(selection, visible, SCOPE)).toBe("all");

    expect(selectedIds(
      reduceSelection(selection, visible, { kind: "none" }, SCOPE),
      visible,
      SCOPE,
    )).toEqual([]);
  });

  test("keeps a hidden id committed without returning it", () => {
    const visible = rows("a", "b", "c");
    let selection = reduceSelection(emptySelection(SCOPE), visible, { kind: "toggle", index: 0 }, SCOPE);
    selection = reduceSelection(selection, visible, { kind: "toggle", index: 1 }, SCOPE);
    expect(selection.committed.has("a")).toBeTrue();
    expect(selectedIds(selection, rows("b", "c"), SCOPE)).toEqual(["b"]);
    expect(selectedIds(selection, visible, SCOPE)).toEqual(["a", "b"]);
  });

  test("falls back to a toggle when the range anchor is stale", () => {
    const initial = rows("a", "b", "c");
    let selection = reduceSelection(emptySelection(SCOPE), initial, { kind: "toggle", index: 0 }, SCOPE);
    const narrowed = rows("b", "c");
    selection = reduceSelection(selection, narrowed, { kind: "extend", index: 1 }, SCOPE);
    expect(selectedIds(selection, narrowed, SCOPE)).toEqual(["c"]);
    expect(selection.range?.anchorId).toBe("c");
  });

  test("replaces the selection outright for the rows a bulk write left unresolved", () => {
    const visible = rows("a", "b", "c", "d");
    let selection = reduceSelection(emptySelection(SCOPE), visible, { kind: "all" }, SCOPE);
    selection = reduceSelection(selection, visible, { kind: "only", ids: ["b", "d", "gone"] }, SCOPE);
    expect(selectedIds(selection, visible, SCOPE)).toEqual(["b", "d"]);
    expect(selection.range).toBeNull();
    expect(headerState(selection, visible, SCOPE)).toBe("some");
    expect(selectedIds(reduceSelection(selection, visible, { kind: "only", ids: [] }, SCOPE), visible, SCOPE)).toEqual([]);
  });

  test("ignores ticks from another filter scope", () => {
    const visible = rows("a", "b");
    const selection = reduceSelection(emptySelection(SCOPE), visible, { kind: "toggle", index: 0 }, SCOPE);
    expect(selectedIds(selection, visible, "other-scope")).toEqual([]);
    const moved = reduceSelection(selection, visible, { kind: "toggle", index: 1 }, "other-scope");
    expect(selectedIds(moved, visible, "other-scope")).toEqual(["b"]);
    expect(selectedIds(moved, visible, SCOPE)).toEqual([]);
  });
});
