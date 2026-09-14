export type SelectionRange = {
  readonly anchorId: string;
  readonly leadId: string;
  readonly mode: "select" | "deselect";
};

export type RegisterSelection = {
  readonly scopeKey: string;
  readonly committed: ReadonlySet<string>;
  readonly range: SelectionRange | null;
};

export type RegisterSelectionIntent =
  | { readonly kind: "toggle"; readonly index: number }
  | { readonly kind: "extend"; readonly index: number }
  | { readonly kind: "all" }
  | { readonly kind: "none" }
  /** Replace the selection outright, e.g. with the rows a bulk write left unresolved. */
  | { readonly kind: "only"; readonly ids: readonly string[] };

export type RegisterSelectionRow = {
  readonly id: string;
};

export type HeaderState = "none" | "some" | "all";

export function emptySelection(scopeKey: string): RegisterSelection {
  return { scopeKey, committed: new Set<string>(), range: null };
}

export const EMPTY_SELECTION = emptySelection("");

function scopedSelection(selection: RegisterSelection, scopeKey: string): RegisterSelection {
  return selection.scopeKey === scopeKey ? selection : emptySelection(scopeKey);
}

function rangeBounds(
  range: SelectionRange,
  rows: readonly RegisterSelectionRow[],
): readonly [number, number] | null {
  const anchorIndex = rows.findIndex((row) => row.id === range.anchorId);
  const leadIndex = rows.findIndex((row) => row.id === range.leadId);
  if (anchorIndex < 0 || leadIndex < 0) {
    return null;
  }
  return [Math.min(anchorIndex, leadIndex), Math.max(anchorIndex, leadIndex)];
}

function foldRange(
  selection: RegisterSelection,
  rows: readonly RegisterSelectionRow[],
): Set<string> {
  const committed = new Set(selection.committed);
  if (!selection.range) {
    return committed;
  }
  const bounds = rangeBounds(selection.range, rows);
  if (!bounds) {
    return committed;
  }
  for (let index = bounds[0]; index <= bounds[1]; index += 1) {
    const row = rows[index];
    if (!row) {
      continue;
    }
    if (selection.range.mode === "select") {
      committed.add(row.id);
    } else {
      committed.delete(row.id);
    }
  }
  return committed;
}

export function selectedIds(
  selection: RegisterSelection,
  rows: readonly RegisterSelectionRow[],
  scopeKey: string,
): readonly string[] {
  const selected = foldRange(scopedSelection(selection, scopeKey), rows);
  return rows.filter((row) => selected.has(row.id)).map((row) => row.id);
}

export function reduceSelection(
  selection: RegisterSelection,
  rows: readonly RegisterSelectionRow[],
  intent: RegisterSelectionIntent,
  scopeKey: string,
): RegisterSelection {
  const current = scopedSelection(selection, scopeKey);
  if (intent.kind === "none") {
    return emptySelection(scopeKey);
  }
  if (intent.kind === "all") {
    const committed = foldRange(current, rows);
    for (const row of rows) {
      committed.add(row.id);
    }
    return { scopeKey, committed, range: null };
  }
  if (intent.kind === "only") {
    return { scopeKey, committed: new Set(intent.ids), range: null };
  }

  const row = rows[intent.index];
  if (!row) {
    return current;
  }
  if (intent.kind === "extend") {
    const anchorExists = current.range
      && rows.some((candidate) => candidate.id === current.range?.anchorId);
    if (anchorExists && current.range) {
      return {
        scopeKey,
        committed: current.committed,
        range: { ...current.range, leadId: row.id },
      };
    }
  }

  const committed = foldRange(current, rows);
  const mode = committed.has(row.id) ? "deselect" : "select";
  return {
    scopeKey,
    committed,
    range: { anchorId: row.id, leadId: row.id, mode },
  };
}

export function headerState(
  selection: RegisterSelection,
  rows: readonly RegisterSelectionRow[],
  scopeKey: string,
): HeaderState {
  const count = selectedIds(selection, rows, scopeKey).length;
  if (count === 0) {
    return "none";
  }
  return count === rows.length ? "all" : "some";
}
