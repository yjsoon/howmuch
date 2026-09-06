export const MAX_REGISTER_QUERY_LENGTH = 200;

export type MoneyFormat = {
  decimalDigits?: number;
  decimalSeparator?: string;
  groupSeparator?: string;
  currencySymbol?: string;
  decimal_digits?: number;
  decimal_separator?: string;
  group_separator?: string;
  currency_symbol?: string;
};

export const DEFAULT_MONEY_FORMAT: MoneyFormat = {
  decimalDigits: 2,
  decimalSeparator: ".",
  groupSeparator: ",",
  currencySymbol: "$",
};

export type AmountSign = "any" | "inflow" | "outflow";

export type AmountRange = {
  lo: number;
  hi: number;
  sign: AmountSign;
};

export type RegisterQuery = {
  raw: string;
  text: string;
  amount: AmountRange | null;
};

export type SearchableLine = {
  payeeName?: string | null;
  memo?: string | null;
  categoryName?: string | null;
  amountMilli?: number | null;
};

export type SearchableFields = SearchableLine & {
  accountName?: string | null;
  lines?: SearchableLine[];
};

export function parseRegisterQuery(raw: string, format?: MoneyFormat | null): RegisterQuery | null {
  const trimmed = raw.trim();
  if (!trimmed) {
    return null;
  }
  return {
    raw: trimmed,
    text: trimmed.toLowerCase(),
    amount: parseAmountRange(trimmed, resolveMoneyFormat(format)),
  };
}

export function matchesRegisterQuery(query: RegisterQuery, fields: SearchableFields): boolean {
  if (containsText(query.text, fields)) {
    return true;
  }
  const amount = query.amount;
  if (!amount) {
    return false;
  }
  if (amountMatches(amount, fields.amountMilli)) {
    return true;
  }
  return fields.lines?.some((line) => amountMatches(amount, line.amountMilli)) === true;
}

export function transactionSearchSql(query: RegisterQuery): { sql: string; params: unknown[] } {
  const params: unknown[] = [];
  const textParts = [
    "instr(lower(ifnull(p.name, ifnull(t.payee_name_snapshot, ''))), ?) > 0",
    "instr(lower(ifnull(t.memo, '')), ?) > 0",
    "instr(lower(ifnull(c.name, ifnull(t.category_name_snapshot, ''))), ?) > 0",
    "instr(lower(a.name), ?) > 0",
    `EXISTS (
            SELECT 1 FROM subtransactions s
            LEFT JOIN payees sp ON sp.id = s.payee_id
            LEFT JOIN categories sc ON sc.id = s.category_id
            WHERE s.transaction_id = t.id AND s.deleted = 0 AND (
              instr(lower(ifnull(sp.name, ifnull(s.payee_name_snapshot, ''))), ?) > 0
              OR instr(lower(ifnull(s.memo, '')), ?) > 0
              OR instr(lower(ifnull(sc.name, ifnull(s.category_name_snapshot, ''))), ?) > 0
            )
          )`,
  ];
  params.push(query.text, query.text, query.text, query.text, query.text, query.text, query.text);

  const clauses = [`(${textParts.join(" OR ")})`];
  if (query.amount) {
    const parent = amountSql("t.amount_milli", query.amount);
    const split = amountSql("s.amount_milli", query.amount);
    clauses.push(`(${parent.sql})`);
    clauses.push(
      `EXISTS (SELECT 1 FROM subtransactions s WHERE s.transaction_id = t.id AND s.deleted = 0 AND (${split.sql}))`,
    );
    params.push(...parent.params, ...split.params);
  }

  return { sql: `(${clauses.join(" OR ")})`, params };
}

function resolveMoneyFormat(format?: MoneyFormat | null): Required<Pick<MoneyFormat, "decimalDigits" | "decimalSeparator" | "groupSeparator" | "currencySymbol">> {
  return {
    decimalDigits: format?.decimalDigits ?? format?.decimal_digits ?? DEFAULT_MONEY_FORMAT.decimalDigits ?? 2,
    decimalSeparator: format?.decimalSeparator ?? format?.decimal_separator ?? DEFAULT_MONEY_FORMAT.decimalSeparator ?? ".",
    groupSeparator: format?.groupSeparator ?? format?.group_separator ?? DEFAULT_MONEY_FORMAT.groupSeparator ?? ",",
    currencySymbol: format?.currencySymbol ?? format?.currency_symbol ?? DEFAULT_MONEY_FORMAT.currencySymbol ?? "$",
  };
}

function parseAmountRange(raw: string, format: {
  decimalSeparator: string;
  groupSeparator: string;
  currencySymbol: string;
}): AmountRange | null {
  let source = raw.replace(/\u2212/g, "-").trim();
  let sign: AmountSign = "any";
  if (source.startsWith("+")) {
    sign = "inflow";
    source = source.slice(1).trim();
  } else if (source.startsWith("-")) {
    sign = "outflow";
    source = source.slice(1).trim();
  }

  const symbol = format.currencySymbol ?? "";
  if (symbol && source.startsWith(symbol)) {
    source = source.slice(symbol.length).trim();
  } else if (symbol && source.endsWith(symbol)) {
    source = source.slice(0, -symbol.length).trim();
  }
  if (sign === "any" && source.startsWith("-")) {
    sign = "outflow";
    source = source.slice(1).trim();
  } else if (sign === "any" && source.startsWith("+")) {
    sign = "inflow";
    source = source.slice(1).trim();
  }

  const groupSeparator = format.groupSeparator ?? ",";
  if (groupSeparator) {
    source = source.split(groupSeparator).join("");
  }

  const decimalSeparator = format.decimalSeparator ?? ".";
  const escaped = decimalSeparator.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = source.match(new RegExp(`^(\\d+)(?:${escaped}(\\d*))?$`));
  if (!match) {
    return null;
  }

  const fraction = match[2];
  const typedFractionDigits = fraction === undefined ? 0 : Math.min(fraction.length, 3);
  const lo = Number(match[1]) * 1000 + Number((fraction ?? "").padEnd(3, "0").slice(0, 3));
  if (!Number.isSafeInteger(lo)) {
    return null;
  }
  const step = 10 ** (3 - typedFractionDigits);
  return { lo, hi: lo + step, sign };
}

function containsText(needle: string, fields: SearchableFields): boolean {
  const haystack = [
    fields.payeeName,
    fields.memo,
    fields.categoryName,
    fields.accountName,
    ...(fields.lines ?? []).flatMap((line) => [line.payeeName, line.memo, line.categoryName]),
  ];
  return haystack.some((value) => value?.toLowerCase().includes(needle) === true);
}

function amountMatches(range: AmountRange, amountMilli: number | null | undefined): boolean {
  if (amountMilli == null) {
    return false;
  }
  if (range.sign === "outflow" && amountMilli >= 0) {
    return false;
  }
  if (range.sign === "inflow" && amountMilli <= 0) {
    return false;
  }
  const magnitude = Math.abs(amountMilli);
  return magnitude >= range.lo && magnitude < range.hi;
}

function amountSql(column: string, range: AmountRange): { sql: string; params: unknown[] } {
  if (range.sign === "outflow") {
    return { sql: `${column} <= ? AND ${column} > ?`, params: [-range.lo, -range.hi] };
  }
  if (range.sign === "inflow") {
    return { sql: `${column} >= ? AND ${column} < ?`, params: [range.lo, range.hi] };
  }
  return { sql: `abs(${column}) >= ? AND abs(${column}) < ?`, params: [range.lo, range.hi] };
}
