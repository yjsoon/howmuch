/** Focused adaptation of yjsoon/ynab-rewards-tracker category-import and formatter
 * at 60cd90ab8c44c4507515f56364ec00d0c97784d2. Pure contract shared by browser/API.
 * Unlike upstream, malformed values fail review rather than being silently dropped.
 */
import type { CardSpendingTier, CardSubcategory, CreditCard } from "./rewards/types";

export type StatementRow = { date: string; payee: string; memo: string; outflow: string; inflow: string };
export const ROW_FIELDS = ["date", "payee", "memo", "outflow", "inflow"] as const;
export const TERMS_HOSTS = ["www.dbs.com.sg", "www.posb.com.sg", "www.uob.com.sg", "www.ocbc.com", "www.citibank.com.sg", "www.hsbc.com.sg", "www.sc.com"];
export const MAX_IMAGE_BYTES = 5 * 1024 * 1024;
export class ToolInputError extends Error {}
function invalid(): never { throw new ToolInputError("Invalid draft: check JSON, dates, amounts, categories and limits."); }
function object(value: unknown): Record<string, any> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return invalid();
  return value as Record<string, any>;
}
function text(value: unknown, max = 2000): string {
  if (typeof value !== "string" || value.length > max) return invalid();
  return value;
}
function number(value: unknown, positive = false): number {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || value > 1e12 || (positive && value === 0)) return invalid();
  return value;
}
function parseJson(raw: string): unknown {
  try { return JSON.parse(raw.trim().replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "")); }
  catch { return invalid(); }
}
export function parseStatementRows(raw: string, maximumRows = 2000): StatementRow[] {
  const value = parseJson(raw);
  const rows = Array.isArray(value) ? value : object(value).transactions;
  if (!Array.isArray(rows) || rows.length > maximumRows) return invalid();
  return rows.map((value) => {
    const row = object(value);
    const result = Object.fromEntries(ROW_FIELDS.map((key) => [key, text(row[key])])) as StatementRow;
    if (!/^\d{4}-\d{2}-\d{2}$/.test(result.date) || !Number.isFinite(Date.parse(result.date)) || new Date(result.date).toISOString().slice(0, 10) !== result.date) return invalid();
    for (const key of ["outflow", "inflow"] as const) {
      if (result[key] && !/^\d{1,12}(?:\.\d{1,2})?$/.test(result[key])) return invalid();
    }
    if (!!result.outflow === !!result.inflow) return invalid();
    return result;
  });
}
export function statementCsv(rows: StatementRow[]): string {
  // The API limit applies per image; a reviewed export can combine many images.
  const validated = parseStatementRows(JSON.stringify(rows), rows.length);
  const cell = (value: string) => {
    const safe = /^[\s\u0000-\u001f]*[=+\-@]/u.test(value) || /^[\t\r\n]/.test(value) ? `'${value}` : value;
    return /[",\r\n]/.test(safe) ? `"${safe.replaceAll('"', '""')}"` : safe;
  };
  return "Date,Payee,Memo,Outflow,Inflow\r\n" + validated.map((row) => ROW_FIELDS.map((key) => cell(row[key])).join(",") + "\r\n").join("");
}

type Previous = { subcategories?: Array<{ id: string; name: string; flagColor: string } & Partial<Omit<CardSubcategory, "id" | "name" | "flagColor">>>; spendingTiers?: CardSpendingTier[]; earningRate?: number | null };
export type TermsPatch = Pick<CreditCard, "earningRate" | "earningBlockSize" | "minimumSpend" | "maximumSpend" | "spendingTiers"> & { subcategoriesEnabled: true; subcategories: CardSubcategory[] };
const colors = ["red", "orange", "yellow", "green", "blue", "purple"] as const;
const normal = (name: string) => name.trim().toLowerCase().replace(/\s+/g, " ");
const defaults = new Set(["everything else", "everything", "other", "others", "catch-all", "catch all", "catchall", "default", "unflagged", "all other spend", "all other spending"]);
export function compileTermsDraft(raw: string, previous: Previous): { patch: TermsPatch; notes: string[] } {
  const value = object(parseJson(raw));
  if (!Array.isArray(value.buckets) || !value.buckets.length || value.buckets.length > 7) return invalid();
  const notes: string[] = value.notes == null ? [] : Array.isArray(value.notes) && value.notes.length <= 100 ? value.notes.map((n: unknown) => text(n)) : invalid();
  const names = new Set<string>();
  const buckets = value.buckets.map((v: unknown) => {
    const b = object(v); const name = text(b.name, 100).trim();
    if (!name || names.has(normal(name))) return invalid();
    names.add(normal(name));
    if (b.excludeFromRewards != null && typeof b.excludeFromRewards !== "boolean") return invalid();
    if (b.inclusion) notes.push(`${name}: ${text(b.inclusion)} (manual restriction; not automatically enforced)`);
    return { name, rewardValue: number(b.rewardValue), excludeFromRewards: b.excludeFromRewards === true,
      milesBlockSize: b.milesBlockSize == null ? null : number(b.milesBlockSize, true),
      minimumSpend: b.minimumSpend == null ? null : number(b.minimumSpend),
      maximumSpend: b.maximumSpend == null ? null : number(b.maximumSpend) };
  });
  const catchAll = buckets.filter((b) => defaults.has(normal(b.name)));
  const earning = buckets.filter((b) => !defaults.has(normal(b.name)));
  if (catchAll.length > 1 || earning.length > 6) return invalid();
  const oldDefault = previous.subcategories?.find((c) => c.flagColor === "unflagged");
  const limits = value.cardLimits == null ? {} : object(value.cardLimits);
  const effectiveBase = limits.earningRate == null ? previous.earningRate ?? 0 : number(limits.earningRate);
  const ordered = [...earning, catchAll[0] ?? { name: "Everything else", rewardValue: oldDefault?.rewardValue ?? effectiveBase, excludeFromRewards: oldDefault?.excludeFromRewards ?? false, milesBlockSize: null, minimumSpend: null, maximumSpend: null }];
  const oldByName = new Map((previous.subcategories ?? []).map((c) => [normal(c.name), c]));
  const used = new Set<string>();
  const usedIds = new Set<string>();
  // Reserve matching colors first so a new category cannot steal an existing color.
  const reserved = new Set(earning.map((b) => oldByName.get(normal(b.name))?.flagColor).filter(Boolean));
  const now = new Date().toISOString();
  const subcategories = ordered.map((b, priority): CardSubcategory => {
    const isDefault = priority === ordered.length - 1;
    const old = oldByName.get(normal(b.name)) ?? (isDefault ? previous.subcategories?.find((c) => c.flagColor === "unflagged") : undefined);
    const preferred = colors.find((color) => color === old?.flagColor && !used.has(color));
    const flagColor = isDefault ? "unflagged" : preferred ?? colors.find((c) => !used.has(c) && !reserved.has(c)) ?? colors.find((c) => !used.has(c))!;
    used.add(flagColor);
    for (const key of ["milesBlockSize", "minimumSpend", "maximumSpend"] as const) b[key] = b[key] ?? old?.[key] ?? null;
    if (b.maximumSpend !== null && b.maximumSpend > 0 && b.minimumSpend !== null && b.maximumSpend < b.minimumSpend) return invalid();
    const id = old?.id && !usedIds.has(old.id) ? old.id : crypto.randomUUID();
    usedIds.add(id);
    return { ...b, rewardValue: b.excludeFromRewards ? 0 : b.rewardValue, id, flagColor, priority, active: true, createdAt: old?.createdAt ?? now, updatedAt: now };
  });
  const patch: TermsPatch = { subcategoriesEnabled: true, subcategories };
  if (value.cardLimits != null) {
    const limits = object(value.cardLimits);
    for (const key of ["earningRate", "earningBlockSize", "minimumSpend", "maximumSpend"] as const) {
      if (limits[key] != null) patch[key] = number(limits[key], key === "earningBlockSize");
    }
    if (patch.minimumSpend != null && patch.maximumSpend != null && patch.maximumSpend > 0 && patch.minimumSpend > patch.maximumSpend) return invalid();
  }
  if (value.spendingTiers != null) {
    if (!Array.isArray(value.spendingTiers) || value.spendingTiers.length > 30) return invalid();
    const thresholds = new Set<number>();
    patch.spendingTiers = value.spendingTiers.map((v: unknown) => {
      const t = object(v); const spendThreshold = number(t.spendThreshold);
      if (thresholds.has(spendThreshold)) return invalid(); thresholds.add(spendThreshold);
      const earningRate = t.earningRate == null ? null : number(t.earningRate);
      if (t.subcategories != null && (!Array.isArray(t.subcategories) || t.subcategories.length > 7)) return invalid();
      const references = new Set<string>();
      const overrides = (t.subcategories ?? []).map((v: unknown) => {
        const override = object(v);
        const name = normal(text(override.name, 100));
        const category = subcategories.find((s) => normal(s.name) === name);
        if (!category || references.has(category.id)) return invalid();
        references.add(category.id);
        return { subcategoryId: category.id, rewardValue: number(override.rewardValue), maximumSpend: override.maximumSpend == null ? null : number(override.maximumSpend) };
      });
      const defaultCategory = subcategories[subcategories.length - 1];
      if (earningRate !== null && !references.has(defaultCategory.id)) overrides.push({ subcategoryId: defaultCategory.id, rewardValue: earningRate, maximumSpend: defaultCategory.maximumSpend ?? null });
      return { id: crypto.randomUUID(), spendThreshold, earningRate, maximumSpend: t.maximumSpend == null ? null : number(t.maximumSpend), subcategories: overrides };
    }).sort((a: CardSpendingTier, b: CardSpendingTier) => a.spendThreshold - b.spendThreshold);
  } else if (previous.spendingTiers) {
    const nextIds = new Set(subcategories.map((s) => s.id));
    patch.spendingTiers = previous.spendingTiers.map((tier) => ({ ...tier, subcategories: (tier.subcategories ?? []).flatMap((override) => {
      const old = previous.subcategories?.find((s) => s.id === override.subcategoryId);
      const nextId = nextIds.has(override.subcategoryId) ? override.subcategoryId : subcategories.find((s) => old && normal(s.name) === normal(old.name))?.id;
      if (!nextId) { notes.push("An override for a removed category was removed from an existing tier."); return []; }
      return [{ ...override, subcategoryId: nextId }];
    }) }));
  }
  return { patch, notes };
}
