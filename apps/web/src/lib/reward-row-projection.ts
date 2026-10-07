import type { RewardsReport } from "../api/types";
import { formatMoney } from "./money";

/*
 * What one Rewards row says, derived only from the report. A port of
 * apps/ios/HowMuch/Support/RewardRowProjection.swift (RewardRowProjection, RewardRowText,
 * RewardsBoardSummary), so both platforms print the same words for the same report. The
 * precedence, wording, rounding and deadlines are the agreed filled-rows spec's
 * (docs/plans/rewards-filled-rows-agreed-spec.md); the picture (docs/frontend/rewards-exposure-card.md)
 * is mapped from this projection in reward-exposure.ts.
 *
 * Civil dates are read as string parts and counted with Date.UTC, never a local Date, so no
 * device zone or daylight-saving change can move a day.
 */

export type RewardsRow = RewardsReport["cards"][number];
type Calculation = RewardsRow["calculation"];
export type RewardKind = "cashback" | "miles";
/** Web names for the iOS tones: needs is `needsMinimum`. */
export type Tone = "needs" | "earning" | "complete" | "failed" | "neutral";

export type Action =
  | { kind: "qualificationFailed" }
  | { kind: "monthlyMinimum"; remaining: number }
  | { kind: "minimum"; remaining: number }
  | { kind: "nextTier"; remaining: number }
  | { kind: "capHeadroom"; remaining: number }
  | { kind: "minimumMet" }
  /** Past the last spend tier with no card-wide cap; categories may still cap. */
  | { kind: "topTier" }
  /** `terminal` is false for an intermediate cap with no reachable tier left. */
  | { kind: "capReached"; beyond: number; terminal: boolean }
  /** `categoryCaps`: some categories still cap, only the card as a whole does not. */
  | { kind: "noTarget"; categoryCaps: boolean }
  | { kind: "range" };

export interface Deadline {
  end: string;
  /** Inclusive of the as-of day, which is still spendable. */
  days: number;
  kind: "ends" | "resets";
}
export interface Basis { spend: number; target: number }

export type RowException =
  | { kind: "categoriesAtCap"; names: string[]; over: boolean }
  | { kind: "categoriesBelowMinimum"; names: string[] }
  | { kind: "rewardsLocked"; until: string }
  | { kind: "tierCapReached" }
  | { kind: "minimumNotMet" };

export interface RewardRowProjection {
  cardId: string;
  accountId: string;
  title: string;
  rewardType: RewardKind;
  action: Action;
  tone: Tone;
  /** The fill and the spend/target line always share this basis. */
  basis: Basis | null;
  /** 0 to 1, or null when there is no target to fill towards. */
  fill: number | null;
  deadline: Deadline | null;
  totalSpend: number;
  earned: number;
  exceptions: RowException[];
  missedMinimumPeriod: { start: string; end: string } | null;
  /** The calculation's minimum spend, 0 with none. Picture only. */
  minimumAmount: number;
  /** The spend threshold of the active spending tier, 0 with none. Picture only. */
  reachedTierThreshold: number;
}

// ---------------------------------------------------------------- civil dates

const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

function parts(iso: string): [number, number, number] | null {
  const match = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso);
  return match ? [Number(match[1]), Number(match[2]), Number(match[3])] : null;
}

/** `to - from` in whole civil days. */
export function daysBetween(from: string, to: string): number | null {
  const a = parts(from), b = parts(to);
  if (!a || !b) return null;
  return Math.round((Date.UTC(b[0], b[1] - 1, b[2]) - Date.UTC(a[0], a[1] - 1, a[2])) / 86_400_000);
}

/** Reward periods are civil dates in Asia/Singapore, whatever the device zone. */
export function singaporeToday(now: Date = new Date()): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Singapore", year: "numeric", month: "2-digit", day: "2-digit" }).format(now);
}

/** "30 Sep", or "30 Sep 2025" outside the reference year. */
export function shortLabel(iso: string, referenceIso?: string): string {
  const p = parts(iso);
  if (!p) return iso;
  const sameYear = referenceIso ? referenceIso.slice(0, 4) === iso.slice(0, 4) : true;
  const day = `${p[2]} ${MONTHS[p[1] - 1]!.slice(0, 3)}`;
  return sameYear ? day : `${day} ${p[0]}`;
}

/** "July" for a whole calendar month (with the year outside today's), else "15 Jul–14 Aug". */
export function qualificationLabel(start: string, end: string, today: string): string {
  const s = parts(start), e = parts(end);
  if (s && e && s[2] === 1 && e[0] === s[0] && e[1] === s[1] && e[2] === new Date(Date.UTC(s[0], s[1], 0)).getUTCDate()) {
    return start.slice(0, 4) === today.slice(0, 4) ? MONTHS[s[1] - 1]! : `${MONTHS[s[1] - 1]!} ${s[0]}`;
  }
  return `${shortLabel(start, today)}–${shortLabel(end, today)}`;
}

// ------------------------------------------------------------------ projection

/** A finite, positive amount, else 0. */
function amount(x: number | null | undefined): number {
  return typeof x === "number" && Number.isFinite(x) && x > 0 ? x : 0;
}
function clamp01(x: number): number {
  return Number.isFinite(x) ? Math.min(1, Math.max(0, x)) : 0;
}

export function projectRow(row: RewardsRow, asOf: string | null | undefined, isRange: boolean, today: string = singaporeToday()): RewardRowProjection {
  const calc: Calculation = row.calculation;
  const build = (
    action: Action,
    tone: Tone,
    extra: { basis?: Basis | null; fill?: number | null; deadline?: Deadline | null; exceptions?: RowException[]; missed?: { start: string; end: string } | null } = {},
  ): RewardRowProjection => {
    const basis = extra.basis ?? null;
    const tier = (row.card.spendingTiers ?? []).find((t) => t.id === calc.active_spending_tier_id);
    return {
      cardId: row.card.id,
      accountId: row.account_id,
      title: row.card.name,
      rewardType: calc.reward_type,
      action,
      tone,
      basis,
      fill: extra.fill ?? (basis ? (basis.target > 0 ? clamp01(basis.spend / basis.target) : 0) : null),
      deadline: extra.deadline ?? null,
      totalSpend: calc.total_spend,
      earned: calc.reward_earned,
      exceptions: extra.exceptions ?? [],
      missedMinimumPeriod: extra.missed ?? null,
      minimumAmount: amount(calc.minimum_spend),
      reachedTierThreshold: calc.active_spending_tier_id ? amount(tier?.spendThreshold) : 0,
    };
  };

  // A range aggregates several periods; it has no single target or deadline, and the server
  // keeps only the last period's cap flags.
  if (isRange) return build({ kind: "range" }, "neutral");

  const period = asOf ? [...(calc.periods ?? [])].reverse().find((p) => p.start <= asOf && asOf <= p.end) : undefined;
  const deadline = (end: string | undefined, kind: Deadline["kind"]): Deadline | null => {
    if (!asOf || !end) return null;
    const gap = daysBetween(asOf, end);
    return gap == null ? null : { end, days: gap + 1, kind };
  };
  const periodEnd = period?.end;
  const status = calc.qualification_status;
  const activeMonth = asOf ? calc.monthly_qualifications?.find((m) => m.start <= asOf && asOf <= m.end) : undefined;
  const qualificationDay = asOf ?? today;
  const failedMonth = calc.monthly_qualifications?.find((m) => m.status === "failed"
    && (m.end < qualificationDay || (m.end === qualificationDay && qualificationDay < today)));
  // Older reports may have only the authoritative status, with no breakdown.
  const failed = status === "failed" && (failedMonth != null || !calc.monthly_qualifications?.length);
  const qualified = calc.minimum_spend_met && status !== "pending" && status !== "failed";

  let action: Action;
  let tone: Tone;
  let basis: Basis | null = null;
  let fill: number | null = null;
  let due: Deadline | null;
  const exceptions: RowException[] = [];
  const minimum = calc.minimum_spend;
  const maximum = calc.maximum_spend;

  if (failed) {
    action = { kind: "qualificationFailed" }; tone = "failed"; due = deadline(periodEnd, "resets");
  } else if ((status === "pending" || status === "failed") && activeMonth && activeMonth.spend < activeMonth.minimumSpend) {
    action = { kind: "monthlyMinimum", remaining: activeMonth.minimumSpend - activeMonth.spend }; tone = "needs";
    basis = { spend: activeMonth.spend, target: activeMonth.minimumSpend };
    due = deadline(activeMonth.end, "ends");
  } else if (minimum != null && minimum > 0 && calc.total_spend < minimum) {
    // Raw qualifying spend, not the block-rounded counted spend.
    action = { kind: "minimum", remaining: minimum - calc.total_spend }; tone = "needs";
    basis = { spend: calc.total_spend, target: minimum };
    due = deadline(periodEnd, "ends");
  } else if (calc.has_next_spending_tier === true && calc.next_spending_tier_threshold != null && calc.next_spending_tier_threshold > calc.total_spend) {
    const threshold = calc.next_spending_tier_threshold;
    action = { kind: "nextTier", remaining: threshold - calc.total_spend }; tone = "earning";
    basis = { spend: calc.total_spend, target: threshold };
    due = deadline(periodEnd, "ends");
    if (calc.maximum_spend_exceeded) exceptions.push({ kind: "tierCapReached" });
  } else if (maximum != null && maximum > 0 && !calc.maximum_spend_exceeded) {
    // Caps count block-rounded spend.
    action = { kind: "capHeadroom", remaining: Math.max(0, maximum - calc.counted_spend) }; tone = "earning";
    basis = { spend: calc.counted_spend, target: maximum };
    due = deadline(periodEnd, "ends");
  } else if (calc.maximum_spend_exceeded) {
    // The flag is authoritative: it fires once headroom is below one block.
    const terminal = calc.should_stop_using === true || calc.has_next_spending_tier !== true;
    const cap = maximum ?? 0;
    action = { kind: "capReached", beyond: cap > 0 ? Math.max(0, calc.total_spend - cap) : 0, terminal };
    tone = terminal ? "complete" : "earning";
    if (cap > 0) basis = { spend: Math.min(calc.counted_spend, cap), target: cap };
    fill = 1;
    due = deadline(periodEnd, "resets");
  } else if (qualified && (row.card.spendingTiers?.length ?? 0) > 0 && calc.has_next_spending_tier === false && (minimum ?? 0) > 0) {
    // Every threshold is behind: the minimum branch above has passed and no next tier is left.
    // Category caps, if any, show as exceptions.
    action = { kind: "topTier" }; tone = "earning"; fill = 1; due = deadline(periodEnd, "resets");
  } else if (qualified && minimum != null && minimum > 0) {
    action = { kind: "minimumMet" }; tone = "earning";
    basis = { spend: calc.total_spend, target: minimum };
    due = deadline(periodEnd, "resets");
  } else {
    action = { kind: "noTarget", categoryCaps: calc.flags.some((f) => (f.maximumSpend ?? 0) > 0) }; tone = "neutral";
    due = deadline(periodEnd, "resets");
  }

  // A reachable tier or cap is not proof that qualification unlocked rewards.
  if (tone === "earning" && !qualified) tone = "neutral";

  const isMinimumAction = action.kind === "minimum" || action.kind === "monthlyMinimum";
  if (status === "pending" && action.kind !== "monthlyMinimum") {
    const ends = calc.monthly_qualifications?.map((m) => m.end) ?? [];
    const until = ends.length ? ends.reduce((a, b) => (b > a ? b : a)) : periodEnd;
    if (until) exceptions.push({ kind: "rewardsLocked", until });
  } else if (!calc.minimum_spend_met && status !== "failed" && status !== "pending" && !isMinimumAction) {
    // Spend reached the figure but the server still withholds rewards, e.g. an unmet tier
    // minimum. Never imply rewards are unlocked.
    exceptions.push({ kind: "minimumNotMet" });
  }

  if (!calc.maximum_spend_exceeded) {
    const atCap = calc.flags.filter((f) => (f.maximumSpend ?? 0) > 0 && f.maximumSpendExceeded === true);
    if (atCap.length) {
      exceptions.push({ kind: "categoriesAtCap", names: atCap.map((f) => f.name), over: atCap.some((f) => (f.totalSpend ?? 0) > (f.maximumSpend ?? 0)) });
    }
  }
  if (calc.minimum_spend_met) {
    const below = calc.flags.filter((f) => (f.minimumSpend ?? 0) > 0 && f.minimumSpendMet === false);
    if (below.length) exceptions.push({ kind: "categoriesBelowMinimum", names: below.map((f) => f.name) });
  }

  return build(action, tone, { basis, fill, deadline: due, exceptions, missed: failedMonth ? { start: failedMonth.start, end: failedMonth.end } : null });
}

export const isBelowMinimum = (p: RewardRowProjection): boolean => p.action.kind === "minimum" || p.action.kind === "monthlyMinimum";
export const isTerminalCap = (p: RewardRowProjection): boolean => p.action.kind === "capReached" && p.action.terminal;

// ------------------------------------------------------------------------ text

/** Display strings for a projection. Kept apart so tests can assert meaning. */
export interface RowText {
  amount: string | null;
  actionLabel: string;
  deadline: string | null;
  isUrgent: boolean;
  basisLine: string;
  exceptionLines: string[];
  accessibilityValue: string;
}

export const VISIBLE_EXCEPTION_LIMIT = 2;

const money = (value: number): string => formatMoney(Math.round(value * 1000));

export function roundedUpToCent(value: number): number {
  if (!(value > 0)) return 0;
  // The epsilon keeps binary noise (102.0000000001) from adding a cent.
  return Math.ceil(value * 100 - 1e-7) / 100;
}

export function milesString(value: number): string {
  return Math.round(value).toLocaleString("en-GB");
}

function reward(value: number, type: RewardKind): string {
  return type === "miles" ? `${milesString(value)} miles` : money(value);
}

export function deadlineText(deadline: Deadline): string {
  if (deadline.days < 1) return "Period ended";
  if (deadline.kind === "ends") return deadline.days === 1 ? "Last day" : `${deadline.days} days left`;
  return deadline.days === 1 ? "Resets tomorrow" : `Resets in ${deadline.days} days`;
}

export function exceptionText(exception: RowException): string {
  switch (exception.kind) {
    case "categoriesAtCap": {
      const state = exception.over ? "over cap" : "at cap";
      return exception.names.length === 1 ? `${exception.names[0]} ${state}` : `${exception.names.length} categories ${state}`;
    }
    case "categoriesBelowMinimum":
      return exception.names.length === 1 ? `${exception.names[0]} below its minimum` : `${exception.names.length} categories below minimum`;
    case "rewardsLocked": return `Rewards unlock after ${shortLabel(exception.until)}`;
    case "tierCapReached": return "Current tier cap reached";
    case "minimumNotMet": return "Minimum not yet met";
  }
}

/** `today` only decides whether a month label names its year. */
export function rowText(p: RewardRowProjection, today: string = singaporeToday()): RowText {
  const earned = reward(p.earned, p.rewardType);
  let amountText: string | null = null;
  let actionLabel: string;
  switch (p.action.kind) {
    case "qualificationFailed":
      actionLabel = p.missedMinimumPeriod ? `${qualificationLabel(p.missedMinimumPeriod.start, p.missedMinimumPeriod.end, today)} minimum missed` : "Monthly minimum missed";
      break;
    case "monthlyMinimum": amountText = money(roundedUpToCent(p.action.remaining)); actionLabel = "to monthly minimum"; break;
    case "minimum": amountText = money(roundedUpToCent(p.action.remaining)); actionLabel = "to minimum"; break;
    case "nextTier": amountText = money(roundedUpToCent(p.action.remaining)); actionLabel = "to next tier"; break;
    case "capHeadroom": amountText = money(p.action.remaining); actionLabel = "left before bonus cap"; break;
    case "capReached": actionLabel = "Bonus cap reached"; break;
    case "topTier": actionLabel = "Highest tier active"; break;
    case "minimumMet": actionLabel = "Minimum met"; break;
    case "noTarget": actionLabel = p.action.categoryCaps ? "No card cap" : "No cap"; break;
    case "range": amountText = earned; actionLabel = "earned"; break;
  }

  const deadline = p.deadline ? deadlineText(p.deadline) : null;
  const isUrgent = p.deadline ? p.deadline.kind === "ends" && p.deadline.days <= 3 : false;

  let basisLine: string;
  if (p.action.kind === "range") {
    basisLine = `${money(p.totalSpend)} spent`;
  } else if (p.action.kind === "capReached") {
    const spendPart = p.basis ? `${money(p.basis.spend)} / ${money(p.basis.target)}` : `${money(p.totalSpend)} spent`;
    const items = [spendPart, `${earned} earned`];
    if (p.action.beyond > 0) items.push(`${money(p.action.beyond)} beyond cap`);
    basisLine = items.join(" · ");
  } else if (p.basis) {
    basisLine = `${money(p.basis.spend)} / ${money(p.basis.target)} · ${earned} earned`;
  } else {
    basisLine = `${money(p.totalSpend)} spent · ${earned} earned`;
  }

  const allExceptions = p.exceptions.map(exceptionText);
  const exceptionLines = allExceptions.length > VISIBLE_EXCEPTION_LIMIT
    ? [...allExceptions.slice(0, VISIBLE_EXCEPTION_LIMIT), `+${allExceptions.length - VISIBLE_EXCEPTION_LIMIT} more`]
    : allExceptions;

  const spoken: string[] = [amountText ? `${amountText} ${actionLabel}` : actionLabel];
  if (p.basis && p.basis.target > 0 && p.action.kind !== "range") {
    const percent = Math.round(clamp01(p.basis.spend / p.basis.target) * 100);
    spoken.push(`${money(p.basis.spend)} of ${money(p.basis.target)}, ${percent} per cent`);
  } else {
    spoken.push(basisLine);
  }
  if (p.deadline && deadline) spoken.push(`${deadline}, ${p.deadline.kind === "ends" ? "ends" : "period ends"} ${shortLabel(p.deadline.end)}`);
  if (p.action.kind !== "range") spoken.push(`${earned} earned`);
  spoken.push(...allExceptions);

  return { amount: amountText, actionLabel, deadline, isUrgent, basisLine, exceptionLines, accessibilityValue: spoken.join(". ") };
}

// --------------------------------------------------------------------- summary

export interface BoardSummary { earnedLine: string; statusCounts: string[]; line: string }

/** The quiet line under the board controls. Scope is the whole report: Featured and hidden choices never change these numbers. */
export function boardSummary(report: RewardsReport, projections: readonly RewardRowProjection[]): BoardSummary {
  const totals = report.totals;
  let earnedLine: string;
  if (totals.miles > 0 && report.miles_valuation <= 0) earnedLine = `${money(totals.cashback)} cashback · ${milesString(totals.miles)} miles`;
  else if (totals.miles > 0) earnedLine = `≈ ${money(totals.reward_dollars)} earned`;
  else earnedLine = `${money(totals.reward_dollars)} earned`;
  const below = projections.filter(isBelowMinimum).length;
  const failed = projections.filter((p) => p.action.kind === "qualificationFailed").length;
  const capped = projections.filter(isTerminalCap).length;
  const statusCounts = [
    below > 0 ? `${below} below minimum` : null,
    failed > 0 ? `${failed} failed` : null,
    capped > 0 ? `${capped} capped` : null,
  ].filter((entry): entry is string => entry != null);
  return { earnedLine, statusCounts, line: [earnedLine, ...statusCounts].join(" · ") };
}
