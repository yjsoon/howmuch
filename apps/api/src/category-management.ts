/**
 * Pure core for HowMuch-native category management.
 *
 * Parsing, validation and the SQL each mutation needs live here; the SQLite
 * repository runs the statements inside one immediate transaction and the D1
 * repository runs them in one guarded batch. Neither backend adds rules of its
 * own, so the two stay identical.
 *
 * A plan is "native" when it has no YNAB `month` raw objects. The owner's
 * production plan is a YNAB mirror; every write here refuses to touch it.
 */

export type PlannedSql = Readonly<{ sql: string; values: readonly unknown[] }>;

/** Same alphabet as Idempotency-Key, so a UUID or a prefixed id both fit. */
export const ENTITY_ID_PATTERN = /^[A-Za-z0-9._:-]{1,128}$/;
export const MAX_CATEGORY_NAME_LENGTH = 100;

export class CategoryValidationError extends Error {}

export class YnabMirrorPlanError extends Error {
  constructor(message = "This plan mirrors YNAB; categories and snapshots can only be changed on HowMuch-native plans") {
    super(message);
  }
}

export class CategoryInUseError extends Error {
  constructor(message = "Category is still used by transactions or scheduled transactions") {
    super(message);
  }
}

export class EntityConflictError extends Error {}

/** Plan-level: one YNAB month object anywhere makes the whole plan a mirror. */
export const YNAB_MONTH_PRESENT_SQL =
  "SELECT 1 AS present FROM ynab_raw_objects WHERE plan_id = ? AND object_type = 'month' LIMIT 1";

/**
 * True while any live ledger row or live schedule still names the category.
 * Takes the plan id and category id four times, in that order.
 */
export const CATEGORY_IN_USE_CONDITION = `(
  EXISTS (SELECT 1 FROM transactions WHERE plan_id = ? AND category_id = ? AND deleted = 0)
  OR EXISTS (
    SELECT 1 FROM subtransactions s JOIN transactions t ON t.id = s.transaction_id
    WHERE t.plan_id = ? AND s.category_id = ? AND s.deleted = 0 AND t.deleted = 0
  )
  OR EXISTS (SELECT 1 FROM scheduled_transaction_edits WHERE plan_id = ? AND category_id = ? AND deleted = 0)
  OR EXISTS (
    SELECT 1 FROM scheduled_subtransaction_edits s
    JOIN scheduled_transaction_edits e ON e.plan_id = s.plan_id AND e.id = s.scheduled_transaction_id
    WHERE s.plan_id = ? AND s.category_id = ? AND e.deleted = 0
  )
)`;

export function categoryInUseValues(planId: string, categoryId: string): unknown[] {
  return [planId, categoryId, planId, categoryId, planId, categoryId, planId, categoryId];
}

export type CategoryGroupCreate = { id?: string; name: string; hidden: boolean };
export type CategoryGroupPatch = { name?: string; hidden?: boolean };
export type CategoryCreate = { id?: string; category_group_id: string; name: string; hidden: boolean };
export type CategoryPatch = { name?: string; hidden?: boolean; category_group_id?: string };

export function parseCategoryGroupCreate(value: unknown): CategoryGroupCreate {
  const input = objectBody(value, "category_group", ["id", "name", "hidden"]);
  return {
    ...(input.id === undefined || input.id === null ? {} : { id: entityId(input.id, "category_group.id") }),
    name: categoryName(input.name, "category_group.name"),
    hidden: optionalBoolean(input.hidden, "category_group.hidden") ?? false,
  };
}

export function parseCategoryGroupPatch(value: unknown): CategoryGroupPatch {
  const input = objectBody(value, "category_group", ["name", "hidden"]);
  const patch: CategoryGroupPatch = {
    ...(input.name === undefined ? {} : { name: categoryName(input.name, "category_group.name") }),
    ...(input.hidden === undefined ? {} : { hidden: optionalBoolean(input.hidden, "category_group.hidden")! }),
  };
  if (patch.name === undefined && patch.hidden === undefined) {
    throw new CategoryValidationError("category_group.name or category_group.hidden is required");
  }
  return patch;
}

export function parseCategoryCreate(value: unknown): CategoryCreate {
  const input = objectBody(value, "category", ["id", "category_group_id", "name", "hidden"]);
  return {
    ...(input.id === undefined || input.id === null ? {} : { id: entityId(input.id, "category.id") }),
    category_group_id: entityId(input.category_group_id, "category.category_group_id"),
    name: categoryName(input.name, "category.name"),
    hidden: optionalBoolean(input.hidden, "category.hidden") ?? false,
  };
}

export function parseCategoryPatch(value: unknown): CategoryPatch {
  const input = objectBody(value, "category", ["name", "hidden", "category_group_id"]);
  const patch: CategoryPatch = {
    ...(input.name === undefined ? {} : { name: categoryName(input.name, "category.name") }),
    ...(input.hidden === undefined ? {} : { hidden: optionalBoolean(input.hidden, "category.hidden")! }),
    ...(input.category_group_id === undefined ? {} : { category_group_id: entityId(input.category_group_id, "category.category_group_id") }),
  };
  if (patch.name === undefined && patch.hidden === undefined && patch.category_group_id === undefined) {
    throw new CategoryValidationError("category.name, category.hidden, or category.category_group_id is required");
  }
  return patch;
}

export function entityId(value: unknown, label: string): string {
  if (typeof value !== "string" || !ENTITY_ID_PATTERN.test(value)) {
    throw new CategoryValidationError(`${label} must be 1-128 letters, numbers, dots, underscores, colons, or hyphens`);
  }
  return value;
}

export function categoryName(value: unknown, label: string): string {
  if (typeof value !== "string") throw new CategoryValidationError(`${label} is required`);
  const name = value.trim();
  if (!name || name.length > MAX_CATEGORY_NAME_LENGTH || /[\u0000-\u001f\u007f]/u.test(name)) {
    throw new CategoryValidationError(`${label} must be 1-${MAX_CATEGORY_NAME_LENGTH} visible characters`);
  }
  return name;
}

function optionalBoolean(value: unknown, label: string): boolean | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value !== "boolean") throw new CategoryValidationError(`${label} must be a boolean`);
  return value;
}

function objectBody(value: unknown, label: string, allowed: readonly string[]): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new CategoryValidationError(`${label} is required`);
  }
  const input = value as Record<string, unknown>;
  for (const key of Object.keys(input)) {
    if (!allowed.includes(key)) throw new CategoryValidationError(`${label}.${key} cannot be set`);
  }
  return input;
}

/** Stored row shapes the mutations read before planning a write. */
export type CategoryGroupRow = { id: string; plan_id: string; name: string; hidden: number; internal: number; deleted: number };
export type CategoryRow = CategoryGroupRow & { category_group_id: string | null };

const BUMP_KNOWLEDGE_SQL = "UPDATE plans SET server_knowledge = server_knowledge + 1, updated_at = CURRENT_TIMESTAMP WHERE id = ?";

function sql(text: string, values: unknown[]): PlannedSql {
  return Object.freeze({ sql: text, values: Object.freeze([...values]) });
}

function audit(auditId: string, planId: string, action: string, resourceType: string, resourceId: string, metadata: unknown): PlannedSql {
  return sql(
    "INSERT INTO audit_events(id,plan_id,action,resource_type,resource_id,source,metadata_json) VALUES (?,?,?,?,?,'howmuch-local',?)",
    [auditId, planId, action, resourceType, resourceId, JSON.stringify(metadata)],
  );
}

/**
 * The write every category command shares: its row change, one knowledge
 * bump (clients revalidate cached categories against it), and an audit row
 * whose metadata carries the request hash for SQLite idempotent replay.
 */
export type CategoryCommand = Readonly<{
  action: "category_group.create" | "category_group.update" | "category.create" | "category.update" | "category.delete";
  resourceType: "category_group" | "category";
  resourceId: string;
  statements: readonly PlannedSql[];
}>;

export function categoryCommandStatements(command: CategoryCommand, planId: string, auditId: string, requestHash: string): PlannedSql[] {
  return [
    ...command.statements,
    sql(BUMP_KNOWLEDGE_SQL, [planId]),
    audit(auditId, planId, command.action, command.resourceType, command.resourceId, { request_hash: requestHash }),
  ];
}

export function createCategoryGroupCommand(planId: string, id: string, input: CategoryGroupCreate): CategoryCommand {
  return {
    action: "category_group.create",
    resourceType: "category_group",
    resourceId: id,
    statements: [sql(
      `INSERT INTO category_groups (id, plan_id, name, hidden, internal, external_ynab_id, deleted, updated_at)
       VALUES (?, ?, ?, ?, 0, ?, 0, CURRENT_TIMESTAMP)`,
      [id, planId, input.name, input.hidden ? 1 : 0, id],
    )],
  };
}

export function updateCategoryGroupCommand(planId: string, current: CategoryGroupRow, patch: CategoryGroupPatch): CategoryCommand {
  if (current.internal) throw new CategoryValidationError("Internal category groups cannot be changed");
  return {
    action: "category_group.update",
    resourceType: "category_group",
    resourceId: current.id,
    statements: [sql(
      `UPDATE category_groups SET name = COALESCE(?, name), hidden = COALESCE(?, hidden), updated_at = CURRENT_TIMESTAMP
       WHERE id = ? AND plan_id = ? AND deleted = 0 AND internal = 0`,
      [patch.name ?? null, patch.hidden === undefined ? null : patch.hidden ? 1 : 0, current.id, planId],
    )],
  };
}

export function createCategoryCommand(planId: string, id: string, input: CategoryCreate, group: CategoryGroupRow): CategoryCommand {
  if (group.internal) throw new CategoryValidationError("Categories cannot be added to an internal category group");
  return {
    action: "category.create",
    resourceType: "category",
    resourceId: id,
    statements: [sql(
      `INSERT INTO categories (id, plan_id, category_group_id, name, hidden, internal, external_ynab_id, deleted, updated_at)
       VALUES (?, ?, ?, ?, ?, 0, ?, 0, CURRENT_TIMESTAMP)`,
      [id, planId, input.category_group_id, input.name, input.hidden ? 1 : 0, id],
    )],
  };
}

export function updateCategoryCommand(planId: string, current: CategoryRow, patch: CategoryPatch, targetGroup: CategoryGroupRow | null): CategoryCommand {
  if (current.internal) throw new CategoryValidationError("Internal categories cannot be changed");
  if (targetGroup?.internal) throw new CategoryValidationError("Categories cannot be moved into an internal category group");
  return {
    action: "category.update",
    resourceType: "category",
    resourceId: current.id,
    statements: [sql(
      `UPDATE categories SET name = COALESCE(?, name), hidden = COALESCE(?, hidden), category_group_id = COALESCE(?, category_group_id), updated_at = CURRENT_TIMESTAMP
       WHERE id = ? AND plan_id = ? AND deleted = 0 AND internal = 0`,
      [
        patch.name ?? null,
        patch.hidden === undefined ? null : patch.hidden ? 1 : 0,
        patch.category_group_id ?? null,
        current.id,
        planId,
      ],
    )],
  };
}

export function deleteCategoryCommand(planId: string, current: CategoryRow): CategoryCommand {
  if (current.internal) throw new CategoryValidationError("Internal categories cannot be deleted");
  return {
    action: "category.delete",
    resourceType: "category",
    resourceId: current.id,
    statements: [sql(
      `UPDATE categories SET deleted = 1, updated_at = CURRENT_TIMESTAMP
       WHERE id = ? AND plan_id = ? AND deleted = 0 AND internal = 0 AND NOT ${CATEGORY_IN_USE_CONDITION}`,
      [current.id, planId, ...categoryInUseValues(planId, current.id)],
    )],
  };
}

/**
 * D1 in-batch preconditions.
 *
 * `write_assertions` only accepts its fixed kinds, and adding one means
 * rebuilding the table. A conditional insert of a `category` assertion whose
 * target can never be a category id (`#` is outside ENTITY_ID_PATTERN) reuses
 * the existing guard trigger: when the condition holds, the trigger finds no
 * such category and aborts the whole batch with "write precondition failed".
 */
export function conditionalAbort(commandId: string, planId: string, guard: string, condition: string, values: readonly unknown[]): PlannedSql {
  return sql(
    `INSERT INTO write_assertions (command_id, kind, target_id, plan_id)
     SELECT ?, 'category', ?, ? WHERE ${condition}`,
    [commandId, `#guard/${guard}`, planId, ...values],
  );
}

export function ynabMirrorGuard(commandId: string, planId: string): PlannedSql {
  return conditionalAbort(
    commandId,
    planId,
    "ynab-mirror-plan",
    "EXISTS (SELECT 1 FROM ynab_raw_objects WHERE plan_id = ? AND object_type = 'month')",
    [planId],
  );
}

export function categoryInUseGuard(commandId: string, planId: string, categoryId: string): PlannedSql {
  return conditionalAbort(commandId, planId, "category-in-use", CATEGORY_IN_USE_CONDITION, categoryInUseValues(planId, categoryId));
}

export function isPreconditionFailure(error: unknown): boolean {
  return String(error).includes("write precondition failed");
}

export function isUniqueViolation(error: unknown): boolean {
  return /UNIQUE constraint failed|PRIMARY KEY/i.test(String(error));
}
