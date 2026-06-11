import { createHash } from "node:crypto";
import type { LedgerRepository } from "../repository";
import type { ClearedState, TransactionInput } from "../types";

export type YnabExportImportOptions = {
  planId: string;
  planName?: string;
  registerCsv: string;
  planCsv?: string;
  dateFormat?: "dmy" | "mdy" | "ymd";
};

type CsvRow = Record<string, string>;

type PreparedTransaction = {
  row: CsvRow;
  index: number;
  input: TransactionInput;
};

export type YnabExportImportResult = {
  import_session_id: string;
  imported: number;
  duplicate: number;
  failed: number;
  transfer_pairs: number;
  accounts: number;
  category_groups: number;
  categories: number;
  payees: number;
};

export function importYnabExport(
  repo: LedgerRepository,
  options: YnabExportImportOptions,
): YnabExportImportResult {
  const sessionId = repo.createImportSession(options.planId, "ynab-web-export");
  const dateFormat = options.dateFormat ?? "dmy";
  const registerRows = parseDelimited(options.registerCsv);
  const planRows = options.planCsv ? parseDelimited(options.planCsv) : [];

  const accountIds = new Set<string>();
  const categoryGroupIds = new Set<string>();
  const categoryIds = new Set<string>();
  const payeeNames = new Set<string>();
  const preparedTransactions: PreparedTransaction[] = [];
  let imported = 0;
  let duplicate = 0;
  let failed = 0;

  try {
    const months = planRows.map((row) => normaliseMonth(row.Month)).filter(Boolean) as string[];
    repo.upsertPlan(
      options.planId,
      {
        id: options.planId,
        name: options.planName ?? "YNAB Web Export",
        first_month: months.length > 0 ? months.sort()[0] : undefined,
        last_month: months.length > 0 ? months.sort()[months.length - 1] : undefined,
      },
      {
        date_format: { format: dateFormat === "mdy" ? "MM/DD/YYYY" : dateFormat === "ymd" ? "YYYY-MM-DD" : "DD/MM/YYYY" },
        currency_format: {
          iso_code: "SGD",
          example_format: "$123,456.78",
          decimal_digits: 2,
          decimal_separator: ".",
          symbol_first: true,
          group_separator: ",",
          currency_symbol: "$",
          display_symbol: true,
        },
        display: { flag_names: {} },
      },
    );

    for (const row of planRows) {
      const category = categoryFromRow(options.planId, row);
      if (!category) {
        continue;
      }
      repo.upsertCategoryGroup(options.planId, {
        id: category.groupId,
        name: category.groupName,
        external_ynab_id: category.groupId,
      });
      repo.upsertCategory(
        options.planId,
        {
          id: category.categoryId,
          name: category.categoryName,
          external_ynab_id: category.categoryId,
        },
        category.groupId,
      );
      categoryGroupIds.add(category.groupId);
      categoryIds.add(category.categoryId);
    }

    registerRows.forEach((row, index) => {
      try {
        const accountName = clean(row.Account);
        if (!accountName) {
          throw new Error("Account is required");
        }

        const accountId = stableId("ynab-export-account", accountName);
        accountIds.add(accountId);
        repo.upsertAccount(options.planId, {
          id: accountId,
          name: accountName,
          external_ynab_id: accountId,
        });

        const category = categoryFromRow(options.planId, row);
        if (category) {
          repo.upsertCategoryGroup(options.planId, {
            id: category.groupId,
            name: category.groupName,
            external_ynab_id: category.groupId,
          });
          repo.upsertCategory(
            options.planId,
            {
              id: category.categoryId,
              name: category.categoryName,
              external_ynab_id: category.categoryId,
            },
            category.groupId,
          );
          categoryGroupIds.add(category.groupId);
          categoryIds.add(category.categoryId);
        }

        const payeeName = clean(row.Payee) || null;
        if (payeeName) {
          payeeNames.add(payeeName);
        }

        const input: TransactionInput = {
          id: stableId(
            "ynab-export-txn",
            [
              index,
              accountName,
              row.Date,
              row.Payee,
              row["Category Group/Category"],
              row.Memo,
              row.Outflow,
              row.Inflow,
              row.Cleared,
            ].join("|"),
          ),
          account_id: accountId,
          date: parseExportDate(row.Date, dateFormat),
          amount: parseInflowOutflow(row.Outflow, row.Inflow),
          payee_name: payeeName,
          memo: clean(row.Memo) || null,
          category_id: category?.categoryId ?? null,
          cleared: parseCleared(row.Cleared),
          approved: true,
          flag_name: clean(row.Flag) || null,
          import_id: stableId(
            "ynab-export-import",
            [index, accountName, row.Date, row.Payee, row.Memo, row.Outflow, row.Inflow].join("|"),
          ),
          source_kind: "ynab-web-export",
          source_ref: sessionId,
          external_ynab_id: null,
        };

        preparedTransactions.push({ row, index, input });
      } catch (error) {
        failed += 1;
        repo.recordImportRow(sessionId, index, "failed", row, error instanceof Error ? error.message : String(error));
      }
    });

    const transferPairs = inferTransferPairs(preparedTransactions);

    for (const prepared of preparedTransactions) {
      try {
        const existing = prepared.input.import_id
          ? repo.findTransactionByImportId(options.planId, prepared.input.import_id)
          : null;
        if (existing) {
          repo.recordImportRow(sessionId, prepared.index, "duplicate", prepared.row, undefined, existing.id);
          duplicate += 1;
          continue;
        }

        const transaction = repo.createTransaction(options.planId, prepared.input);
        repo.recordImportRow(sessionId, prepared.index, "imported", prepared.row, undefined, transaction.id);
        imported += 1;
      } catch (error) {
        failed += 1;
        repo.recordImportRow(
          sessionId,
          prepared.index,
          "failed",
          prepared.row,
          error instanceof Error ? error.message : String(error),
        );
      }
    }

    const summary = {
      imported,
      duplicate,
      failed,
      transfer_pairs: transferPairs,
      accounts: accountIds.size,
      category_groups: categoryGroupIds.size,
      categories: categoryIds.size,
      payees: payeeNames.size,
    };
    repo.finishImportSession(sessionId, failed > 0 ? "completed_with_errors" : "completed", summary);
    return { import_session_id: sessionId, ...summary };
  } catch (error) {
    repo.finishImportSession(sessionId, "failed", { error: error instanceof Error ? error.message : String(error) });
    throw error;
  }
}

export function parseDelimited(content: string): CsvRow[] {
  const normalised = content.replace(/^\uFEFF/, "");
  const firstLine = normalised.split(/\r?\n/, 1)[0] ?? "";
  const separator = firstLine.includes("\t") ? "\t" : ",";
  const rows = parseRows(normalised, separator);
  const [headers = [], ...records] = rows;
  const cleanHeaders = headers.map((header) => clean(header));

  return records
    .filter((record) => record.some((value) => clean(value) !== ""))
    .map((record) => {
      const row: CsvRow = {};
      cleanHeaders.forEach((header, index) => {
        row[header] = clean(record[index] ?? "");
      });
      return row;
    });
}

export function parseExportDate(value: string, format: "dmy" | "mdy" | "ymd" = "dmy"): string {
  const raw = clean(value);
  const iso = raw.match(/^(\d{4})-(\d{1,2})-(\d{1,2})$/);
  if (iso) {
    return [iso[1], pad2(iso[2]), pad2(iso[3])].join("-");
  }

  const slash = raw.match(/^(\d{1,2})[/-](\d{1,2})[/-](\d{2}|\d{4})$/);
  if (!slash) {
    throw new Error(`Invalid YNAB export date: ${value}`);
  }

  const first = Number.parseInt(slash[1], 10);
  const second = Number.parseInt(slash[2], 10);
  const year = slash[3].length === 2 ? 2000 + Number.parseInt(slash[3], 10) : Number.parseInt(slash[3], 10);
  let month: number;
  let day: number;

  if (format === "ymd") {
    month = first;
    day = second;
  } else if (format === "mdy" || (format === "dmy" && second > 12)) {
    month = first;
    day = second;
  } else {
    day = first;
    month = second;
  }

  if (month < 1 || month > 12 || day < 1 || day > 31) {
    throw new Error(`Invalid YNAB export date: ${value}`);
  }

  return `${year}-${pad2(month)}-${pad2(day)}`;
}

export function parseMoneyToMilliunits(value: string): number {
  const raw = clean(value);
  if (!raw) {
    return 0;
  }

  const negative = raw.includes("-") || raw.includes("−") || (raw.startsWith("(") && raw.endsWith(")"));
  const digits = raw.replace(/[^\d.,]/g, "");
  if (!digits) {
    return 0;
  }

  const lastDot = digits.lastIndexOf(".");
  const lastComma = digits.lastIndexOf(",");
  const decimalSeparator = lastComma > lastDot && digits.length - lastComma <= 3 ? "," : ".";
  const groupSeparator = decimalSeparator === "." ? "," : ".";
  const withoutGroups = digits.split(groupSeparator).join("");
  const decimalised = decimalSeparator === "," ? withoutGroups.replace(",", ".") : withoutGroups;
  const [wholePart, fractionPart = ""] = decimalised.split(".");
  const whole = Number.parseInt(wholePart || "0", 10);
  const fraction = Number.parseInt(fractionPart.padEnd(3, "0").slice(0, 3) || "0", 10);

  if (Number.isNaN(whole) || Number.isNaN(fraction)) {
    throw new Error(`Invalid money value: ${value}`);
  }

  const amount = whole * 1000 + fraction;
  return negative ? -amount : amount;
}

function parseRows(content: string, separator: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let field = "";
  let inQuotes = false;

  for (let index = 0; index < content.length; index += 1) {
    const char = content[index];
    const next = content[index + 1];

    if (char === '"') {
      if (inQuotes && next === '"') {
        field += '"';
        index += 1;
      } else {
        inQuotes = !inQuotes;
      }
      continue;
    }

    if (char === separator && !inQuotes) {
      row.push(field);
      field = "";
      continue;
    }

    if ((char === "\n" || char === "\r") && !inQuotes) {
      if (char === "\r" && next === "\n") {
        index += 1;
      }
      row.push(field);
      rows.push(row);
      row = [];
      field = "";
      continue;
    }

    field += char;
  }

  if (field || row.length > 0) {
    row.push(field);
    rows.push(row);
  }

  return rows;
}

function parseInflowOutflow(outflow: string, inflow: string): number {
  const outflowAmount = parseMoneyToMilliunits(outflow);
  if (outflowAmount !== 0) {
    return -Math.abs(outflowAmount);
  }
  return Math.abs(parseMoneyToMilliunits(inflow));
}

function inferTransferPairs(transactions: PreparedTransaction[]): number {
  const byAmount = new Map<number, { positives: PreparedTransaction[]; negatives: PreparedTransaction[] }>();

  for (const transaction of transactions) {
    if (!isTransferCandidate(transaction.input)) {
      continue;
    }

    const amount = Math.abs(transaction.input.amount);
    const bucket = byAmount.get(amount) ?? { positives: [], negatives: [] };
    if (transaction.input.amount > 0) {
      bucket.positives.push(transaction);
    } else {
      bucket.negatives.push(transaction);
    }
    byAmount.set(amount, bucket);
  }

  let pairs = 0;
  for (const bucket of byAmount.values()) {
    const unmatchedPositives = new Set(bucket.positives);
    const negatives = [...bucket.negatives].sort((left, right) => left.input.date.localeCompare(right.input.date));

    for (const negative of negatives) {
      let best: PreparedTransaction | null = null;
      let bestDistance = Number.POSITIVE_INFINITY;

      for (const positive of unmatchedPositives) {
        if (negative.input.account_id === positive.input.account_id) {
          continue;
        }

        const distance = Math.abs(daysBetweenIso(negative.input.date, positive.input.date));
        if (distance > 3 || distance > bestDistance) {
          continue;
        }

        best = positive;
        bestDistance = distance;
      }

      if (!best) {
        continue;
      }

      unmatchedPositives.delete(best);
      negative.input.transfer_transaction_id = best.input.id ?? null;
      negative.input.transfer_account_id = best.input.account_id;
      best.input.transfer_transaction_id = negative.input.id ?? null;
      best.input.transfer_account_id = negative.input.account_id;
      pairs += 1;
    }
  }

  return pairs;
}

function isTransferCandidate(input: TransactionInput): boolean {
  return (
    input.category_id == null &&
    input.amount !== 0 &&
    input.payee_name !== "Starting Balance" &&
    input.transfer_transaction_id == null
  );
}

function daysBetweenIso(left: string, right: string): number {
  const leftDate = Date.UTC(Number(left.slice(0, 4)), Number(left.slice(5, 7)) - 1, Number(left.slice(8, 10)));
  const rightDate = Date.UTC(Number(right.slice(0, 4)), Number(right.slice(5, 7)) - 1, Number(right.slice(8, 10)));
  return Math.round((leftDate - rightDate) / 86400000);
}

function parseCleared(value: string): ClearedState {
  const normalised = clean(value).toLowerCase();
  if (normalised === "cleared") {
    return "cleared";
  }
  if (normalised === "reconciled") {
    return "reconciled";
  }
  return "uncleared";
}

function categoryFromRow(planId: string, row: CsvRow): { groupId: string; groupName: string; categoryId: string; categoryName: string } | null {
  const groupName = clean(row["Category Group"]);
  const categoryName = clean(row.Category);
  if (!groupName || !categoryName) {
    return null;
  }
  const groupId = stableId("ynab-export-category-group", `${planId}:${groupName}`);
  return {
    groupId,
    groupName,
    categoryId: stableId("ynab-export-category", `${planId}:${groupName}:${categoryName}`),
    categoryName,
  };
}

function normaliseMonth(value: string): string | null {
  const raw = clean(value);
  const iso = raw.match(/^(\d{4})-(\d{2})(?:-\d{2})?$/);
  if (iso) {
    return `${iso[1]}-${iso[2]}`;
  }
  const named = raw.match(/^([A-Za-z]+)\s+(\d{4})$/);
  if (!named) {
    return null;
  }
  const month = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"].findIndex(
    (candidate) => named[1].toLowerCase().startsWith(candidate),
  );
  return month >= 0 ? `${named[2]}-${pad2(month + 1)}` : null;
}

function clean(value: unknown): string {
  return String(value ?? "").replace(/^\uFEFF/, "").trim();
}

function stableId(prefix: string, value: string): string {
  return `${prefix}-${createHash("sha256").update(value).digest("hex").slice(0, 20)}`;
}

function pad2(value: string | number): string {
  return String(value).padStart(2, "0");
}
