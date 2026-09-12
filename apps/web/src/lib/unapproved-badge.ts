/**
 * The "New to approve" badge, decoupled from the queue behind it.
 *
 * The register used to page the whole unapproved queue just to render this
 * number. It now comes from `GET .../transactions/unapproved_count`, and the
 * rows are fetched only when the user opens the approval flow. Two sources for
 * one number need a rule for which wins, and a rule for the window between
 * approving something and the next count landing. Both live here, as pure
 * functions, so they can be tested without a server.
 */

/** Ids resolved locally: approved in this session, or deleted from the register. */
export type ResolvedIds = ReadonlySet<string>;

/**
 * How many locally resolved rows the server count cannot know about yet.
 *
 * `whenCounted` is the resolved set as it stood when the current count arrived;
 * anything resolved since is not reflected in it. Snapshotting rather than
 * counting every resolved id is what keeps a refetched count from being
 * decremented twice for the same approval.
 */
export function resolvedSinceCount(resolved: ResolvedIds, whenCounted: ResolvedIds): number {
  let since = 0;
  for (const id of resolved) {
    if (!whenCounted.has(id)) since += 1;
  }
  return since;
}

/**
 * The number to show, or `null` while the first count is still in flight —
 * callers must render nothing rather than a confident zero.
 *
 * `queueCount` is the row-exact count, available only once the approval flow
 * has loaded the queue; it always wins, because it already accounts for every
 * local edit. Otherwise the server count is adjusted down by whatever has been
 * resolved since it was taken, and never falls below zero.
 */
export function unapprovedBadgeCount(
  queueCount: number | null,
  serverCount: number | null,
  resolvedSince: number,
): number | null {
  if (queueCount !== null) return queueCount;
  if (serverCount === null) return null;
  return Math.max(0, serverCount - resolvedSince);
}

/**
 * Whether the badge should be shown at all. A zero badge is noise, but the
 * pill doubles as the way out of the approval flow, so it stays visible while
 * that flow is open.
 */
export function showsUnapprovedBadge(count: number | null, approvalFlowOpen: boolean): boolean {
  return approvalFlowOpen || (count !== null && count > 0);
}
