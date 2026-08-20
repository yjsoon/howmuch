import { Database } from "bun:sqlite";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";

type SourceObject = { type: string; id: string; payload: unknown };

const options = readOptions(process.argv.slice(2));
if (!options.db || !options.planJson) {
  console.error("Usage: bun run verify:ynab-parity --db <howmuch.sqlite> --plan-json <full-plan.json> [--settings <settings.json>] [--money-movements <json>] [--money-movement-groups <json>]");
  process.exit(2);
}

const planEnvelope = readJson(options.planJson);
const plan = planEnvelope?.data?.plan ?? planEnvelope?.data?.budget;
if (!plan || typeof plan !== "object") fail("The supplied full-plan JSON has no data.plan object");
const planId = options.planId ?? String(plan.id ?? "");
if (!planId) fail("The supplied plan has no id; pass --plan-id");

const expectedSettings = readOptionalSettings(options.settings);
const expected = sourceObjects(plan, readOptionalArray(options.moneyMovements, "money_movements"), readOptionalArray(options.moneyMovementGroups, "money_movement_groups"), expectedSettings);
const db = new Database(options.db, { readonly: true, strict: true });
try {
  const failures: string[] = [];
  const fk = db.query("PRAGMA foreign_key_check").all();
  if (fk.length) failures.push(`foreign-key violations=${fk.length}`);

  const actual = db.query("SELECT object_type type, object_id id, payload_json payload_json FROM ynab_raw_objects WHERE plan_id=? ORDER BY object_type,object_id").all(planId) as Array<{ type: string; id: string; payload_json: string }>;
  const byType = groupBy(expected, (object) => object.type);
  const actualByType = groupBy(actual, (object) => object.type);
  // Settings is fetched from YNAB's separate endpoint. Without its snapshot,
  // retain the useful mirror-count report without treating it as drift.
  const settings = actualByType.settings ?? [];
  if (expectedSettings === undefined) console.log(`settings: source=separate-endpoint mirror=${settings.length}`);
  const types = [...new Set([...Object.keys(byType), ...Object.keys(actualByType).filter((type) => expectedSettings === undefined && type !== "settings")])].sort();
  for (const type of types) {
    const wanted = byType[type] ?? [];
    const got = actualByType[type] ?? [];
    const wantedMap = new Map(wanted.map((object) => [object.id, canonicalHash(object.payload)]));
    const gotMap = new Map(got.map((object) => [object.id, canonicalHash(parseJson(object.payload_json, `raw ${type}`))]));
    const missing = [...wantedMap.keys()].filter((id) => !gotMap.has(id));
    const unexpected = [...gotMap.keys()].filter((id) => !wantedMap.has(id));
    const changed = [...wantedMap.keys()].filter((id) => gotMap.has(id) && gotMap.get(id) !== wantedMap.get(id));
    const wantedDigest = setHash(wantedMap);
    const actualDigest = setHash(gotMap);
    console.log(`${type}: source=${wanted.length} mirror=${got.length} source_hash=${wantedDigest} mirror_hash=${actualDigest}`);
    if (missing.length || unexpected.length || changed.length) {
      failures.push(`${type}: missing=[${ids(missing)}] unexpected=[${ids(unexpected)}] changed=[${ids(changed)}]`);
    }
  }

  verifyLedgerCounts(db, planId, plan, failures);
  verifyBalances(db, planId, failures);

  if (failures.length) {
    console.error("YNAB parity verification failed:");
    for (const failure of failures) console.error(`- ${failure}`);
    process.exitCode = 1;
  } else {
    console.log(`YNAB parity verified for plan ${planId}: ${expected.length} source objects, ledger and foreign keys match.`);
  }
} finally {
  db.close();
}

function sourceObjects(plan: any, moneyMovements: any[], moneyMovementGroups: any[], settings?: any): SourceObject[] {
  const result: SourceObject[] = [];
  const add = (type: string, id: unknown, payload: unknown) => result.push({ type, id: String(id), payload });
  add("plan", plan.id, withoutArrays(plan));
  for (const account of plan.accounts ?? []) add("account", account.id, account);
  for (const group of plan.category_groups ?? []) add("category_group", group.id, withoutArrays(group));
  for (const category of plan.categories ?? flatten(plan.category_groups ?? [], "categories")) add("category", category.id, category);
  for (const payee of plan.payees ?? []) add("payee", payee.id, payee);
  for (const location of plan.payee_locations ?? []) add("payee_location", location.id, location);
  for (const month of plan.months ?? []) {
    const monthId = String(month.month ?? month.id);
    add("month", monthId, withoutArrays(month));
    for (const category of month.categories ?? []) add("month_category", compositeId(monthId, category.id), category);
  }
  for (const transaction of plan.transactions ?? []) add("transaction", transaction.id, withoutArrays(transaction));
  for (const subtransaction of plan.subtransactions ?? flatten(plan.transactions ?? [], "subtransactions")) add("subtransaction", compositeId(subtransaction.transaction_id ?? "unknown", subtransaction.id), subtransaction);
  for (const transaction of plan.scheduled_transactions ?? []) add("scheduled_transaction", transaction.id, transaction);
  for (const subtransaction of plan.scheduled_subtransactions ?? flatten(plan.scheduled_transactions ?? [], "subtransactions")) add("scheduled_subtransaction", compositeId(subtransaction.scheduled_transaction_id ?? "unknown", subtransaction.id), subtransaction);
  for (const movement of moneyMovements) add("money_movement", movement.id, movement);
  for (const group of moneyMovementGroups) add("money_movement_group", group.id, group);
  if (settings !== undefined) add("settings", "settings", settings);
  return result;
}

function verifyLedgerCounts(db: Database, planId: string, plan: any, failures: string[]) {
  const checks: Array<[string, string, unknown[]]> = [
    ["accounts", "accounts", plan.accounts ?? []],
    ["payees", "payees", plan.payees ?? []],
    ["transactions", "transactions", plan.transactions ?? []],
    ["subtransactions", "subtransactions", plan.subtransactions ?? flatten(plan.transactions ?? [], "subtransactions")],
  ];
  for (const [table, label, source] of checks) {
    const row = table === "subtransactions"
      ? db.query("SELECT count(*) count FROM subtransactions s JOIN transactions t ON t.id=s.transaction_id WHERE t.plan_id=?").get(planId)
      : db.query(`SELECT count(*) count FROM ${table} WHERE plan_id=?`).get(planId);
    const mirrored = Number((row as any)?.count ?? 0);
    const sourceCount = source.length;
    console.log(`${label} ledger_count=${mirrored} source_count=${sourceCount}`);
    if (mirrored !== sourceCount) failures.push(`${label}: ledger count ${mirrored} does not match source ${sourceCount}`);
  }

  verifyCategoryPlaceholders(db, planId, plan, failures);
}

function verifyCategoryPlaceholders(db: Database, planId: string, plan: any, failures: string[]) {
  const sentinelGroupId = "uncategorized-group";
  const sourceGroups = plan.category_groups ?? [];
  const sourceCategories = plan.categories ?? flatten(sourceGroups, "categories");
  const sourceGroupIds = new Set(sourceGroups.map((group: any) => String(group.id)));
  const sourceCategoryIds = new Set(sourceCategories.map((category: any) => String(category.id)));
  const transactions = plan.transactions ?? [];
  const subtransactions = plan.subtransactions ?? flatten(transactions, "subtransactions");
  const splitParentIds = sourceSplitParentIds(plan, transactions);
  const referencedCategoryIds = new Set<string>();
  for (const row of transactions) {
    // The importer intentionally normalises split-parent categories as null:
    // their line categories are authoritative, while the parent value remains
    // available losslessly in the raw source mirror.
    if (!splitParentIds.has(String(row?.id)) && row?.category_id != null) referencedCategoryIds.add(String(row.category_id));
  }
  for (const row of subtransactions) {
    if (row?.category_id != null) referencedCategoryIds.add(String(row.category_id));
  }
  const placeholderIds = [...referencedCategoryIds].filter((id) => !sourceCategoryIds.has(id)).sort();
  const expectedGroupIds = new Set(sourceGroupIds);
  if (placeholderIds.length) expectedGroupIds.add(sentinelGroupId);
  const expectedCategoryIds = new Set([...sourceCategoryIds, ...placeholderIds]);

  const ledgerGroups = db.query("SELECT id,deleted FROM category_groups WHERE plan_id=? ORDER BY id").all(planId) as Array<{ id: string; deleted: number }>;
  const ledgerCategories = db.query("SELECT id,category_group_id,deleted FROM categories WHERE plan_id=? ORDER BY id").all(planId) as Array<{ id: string; category_group_id: string | null; deleted: number }>;
  const ledgerGroupIds = new Set(ledgerGroups.map((group) => group.id));
  const ledgerCategoryIds = new Set(ledgerCategories.map((category) => category.id));
  const missingGroups = [...expectedGroupIds].filter((id) => !ledgerGroupIds.has(id));
  // Import-time category creation can leave this one sentinel behind after a
  // later source category upsert makes its placeholder unnecessary. An empty,
  // active sentinel is benign; every other non-source group remains drift.
  const unexpectedGroups = [...ledgerGroupIds].filter((id) => !expectedGroupIds.has(id) && id !== sentinelGroupId);
  const missingCategories = [...expectedCategoryIds].filter((id) => !ledgerCategoryIds.has(id));
  const unexpectedCategories = [...ledgerCategoryIds].filter((id) => !expectedCategoryIds.has(id));

  console.log(`category_groups ledger_count=${ledgerGroups.length} source_count=${sourceGroups.length} required_sentinel=${placeholderIds.length ? 1 : 0}`);
  console.log(`categories ledger_count=${ledgerCategories.length} source_count=${sourceCategories.length} required_placeholders=${placeholderIds.length}`);
  if (missingGroups.length || unexpectedGroups.length) failures.push(`category_groups: missing=[${ids(missingGroups)}] unexpected=[${ids(unexpectedGroups)}]`);
  if (missingCategories.length || unexpectedCategories.length) failures.push(`categories: missing=[${ids(missingCategories)}] unexpected=[${ids(unexpectedCategories)}]`);

  const placeholderSet = new Set(placeholderIds);
  const malformedPlaceholders = ledgerCategories
    .filter((category) => placeholderSet.has(category.id))
    .filter((category) => category.category_group_id !== sentinelGroupId || category.deleted !== 0)
    .map((category) => category.id);
  if (malformedPlaceholders.length) failures.push(`categories: malformed required placeholders=[${ids(malformedPlaceholders)}]`);

  if (!sourceGroupIds.has(sentinelGroupId)) {
    const sentinel = ledgerGroups.find((group) => group.id === sentinelGroupId);
    if (sentinel && sentinel.deleted !== 0) failures.push(`category_groups: required sentinel ${sentinelGroupId} is deleted`);
    const unexplained = ledgerCategories
      .filter((category) => category.category_group_id === sentinelGroupId && !placeholderSet.has(category.id))
      .map((category) => category.id);
    if (unexplained.length) failures.push(`category_groups: sentinel contains unexplained categories=[${ids(unexplained)}]`);
  }
}

function sourceSplitParentIds(plan: any, transactions: any[]): Set<string> {
  const result = new Set<string>();
  for (const subtransaction of Array.isArray(plan.subtransactions) ? plan.subtransactions : []) {
    if (subtransaction?.transaction_id != null) result.add(String(subtransaction.transaction_id));
  }
  // Older collection responses embed split lines in their parent instead of
  // providing the full-plan top-level subtransactions array.
  for (const transaction of transactions) {
    for (const subtransaction of transaction?.subtransactions ?? []) {
      result.add(String(subtransaction?.transaction_id ?? transaction.id));
    }
  }
  return result;
}

function verifyBalances(db: Database, planId: string, failures: string[]) {
  const mismatches = db.query(`SELECT a.id
    FROM accounts a
    LEFT JOIN (
      SELECT account_id, COALESCE(sum(CASE WHEN deleted=0 THEN amount_milli ELSE 0 END), 0) amount
      FROM transactions WHERE plan_id=? GROUP BY account_id
    ) t ON t.account_id=a.id
    WHERE a.plan_id=? AND a.deleted=0 AND a.balance_milli<>a.opening_balance_milli+COALESCE(t.amount,0)
    ORDER BY a.id`).all(planId, planId) as Array<{ id: string }>;
  console.log(`account_balance_reconciliation mismatches=${mismatches.length}`);
  if (mismatches.length) failures.push(`account balances disagree with ledger transactions: [${ids(mismatches.map((row) => row.id))}]`);
}

function readOptions(args: string[]) {
  const result: Record<string, string> = {};
  for (let i = 0; i < args.length; i += 2) {
    const key = args[i]; const value = args[i + 1];
    if (!key?.startsWith("--") || !value) fail(`Invalid option near ${key ?? "end of command"}`);
    result[key.slice(2).replace(/-([a-z])/g, (_, letter) => letter.toUpperCase())] = value;
  }
  return result;
}

function readJson(path: string): any { return parseJson(readFileSync(path, "utf8"), "source JSON"); }
function readOptionalArray(path: string | undefined, field: string): any[] {
  if (!path) return [];
  const data = readJson(path)?.data?.[field];
  if (!Array.isArray(data)) fail(`${field} source JSON is not an array`);
  return data;
}
function readOptionalSettings(path: string | undefined): any | undefined {
  if (!path) return undefined;
  const settings = readJson(path)?.data?.settings;
  if (!settings || typeof settings !== "object" || Array.isArray(settings)) fail("settings source JSON has no data.settings object");
  return settings;
}
function parseJson(value: string, label: string): any { try { return JSON.parse(value); } catch { fail(`${label} is invalid JSON`); } }
function withoutArrays(value: any) { return Object.fromEntries(Object.entries(value ?? {}).filter(([, item]) => !Array.isArray(item))); }
function flatten(values: any[], key: string): any[] { return values.flatMap((value) => Array.isArray(value?.[key]) ? value[key] : []); }
function compositeId(parent: unknown, child: unknown) { return `${String(parent)}\u001f${String(child)}`; }
function canonicalHash(value: unknown) { return createHash("sha256").update(JSON.stringify(canonical(value))).digest("hex"); }
function canonical(value: any): any { if (Array.isArray(value)) return value.map(canonical); if (value && typeof value === "object") return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonical(value[key])])); return value; }
function setHash(values: Map<string, string>) { return createHash("sha256").update(JSON.stringify([...values].sort(([a], [b]) => a.localeCompare(b)))).digest("hex"); }
function groupBy<T>(values: T[], key: (value: T) => string): Record<string, T[]> { const result: Record<string, T[]> = {}; for (const value of values) (result[key(value)] ??= []).push(value); return result; }
function ids(values: string[]) { return values.slice(0, 20).join(",") + (values.length > 20 ? `,+${values.length - 20} more` : ""); }
function fail(message: string): never { throw new Error(message); }
