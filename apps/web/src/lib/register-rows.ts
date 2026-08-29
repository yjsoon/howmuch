export type RegisterRow = {
  readonly id: string;
  readonly deleted: boolean;
};

export function replaceRowById<T extends { readonly id: string }>(
  rows: readonly T[],
  next: T,
): T[] {
  return rows.map((row) => (row.id === next.id ? next : row));
}

export function deletedIdsForRemoval(transaction: {
  readonly id: string;
  readonly transfer_transaction_id?: string | null;
  readonly subtransactions?: ReadonlyArray<{
    readonly transfer_transaction_id?: string | null;
  }>;
}): readonly string[] {
  const ids = [transaction.id];
  if (transaction.transfer_transaction_id) {
    ids.push(transaction.transfer_transaction_id);
  }
  for (const line of transaction.subtransactions ?? []) {
    if (line.transfer_transaction_id) {
      ids.push(line.transfer_transaction_id);
    }
  }
  return ids;
}

export function markDeletedByIds<T extends RegisterRow>(
  rows: readonly T[],
  ids: ReadonlySet<string>,
): T[] {
  return rows.map((row) => (ids.has(row.id) && !row.deleted ? { ...row, deleted: true } : row));
}

export function applyRegisterPatches<T extends RegisterRow>(
  rows: readonly T[],
  replacements: ReadonlyMap<string, T>,
  deletedIds: ReadonlySet<string>,
): T[] {
  return markDeletedByIds(
    rows.map((row) => replacements.get(row.id) ?? row),
    deletedIds,
  );
}
