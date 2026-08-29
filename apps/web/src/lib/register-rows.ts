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

export type SplitMirrorLink = {
  readonly id: string;
  readonly parent_transaction_id?: string | null;
  readonly transfer_transaction_id?: string | null;
};

export type SplitParentRow = {
  readonly id: string;
  readonly subtransactions?: ReadonlyArray<{
    readonly id?: string;
    readonly transfer_account_id?: string | null;
    readonly transfer_transaction_id?: string | null;
  }>;
};

function subLinksMirror(
  sub: { readonly id?: string; readonly transfer_transaction_id?: string | null },
  mirror: SplitMirrorLink,
): boolean {
  return (
    sub.transfer_transaction_id === mirror.id
    || (mirror.transfer_transaction_id != null && sub.id === mirror.transfer_transaction_id)
  );
}

export function unlinkSplitMirrorParent<T extends SplitParentRow>(
  rows: readonly T[],
  mirror: SplitMirrorLink,
): T | null {
  const parent =
    (mirror.parent_transaction_id
      ? rows.find((row) => row.id === mirror.parent_transaction_id)
      : undefined)
    ?? rows.find((row) => row.subtransactions?.some((sub) => subLinksMirror(sub, mirror)));
  if (!parent?.subtransactions?.length) {
    return null;
  }
  let changed = false;
  const subtransactions = parent.subtransactions.map((sub) => {
    if (!subLinksMirror(sub, mirror) || (!sub.transfer_account_id && !sub.transfer_transaction_id)) {
      return sub;
    }
    changed = true;
    return { ...sub, transfer_account_id: null, transfer_transaction_id: null };
  });
  return changed ? { ...parent, subtransactions } : null;
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
