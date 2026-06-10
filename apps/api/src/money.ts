export function decimalToMilliunits(value: string | number): number {
  const raw = String(value).trim().replace(/[$,\s]/g, "");
  if (!raw) {
    return 0;
  }

  const sign = raw.startsWith("-") ? -1 : 1;
  const unsigned = raw.replace(/^[+-]/, "");
  const [wholePart, fractionPart = ""] = unsigned.split(".");
  const whole = Number.parseInt(wholePart || "0", 10);
  const fraction = Number.parseInt(fractionPart.padEnd(3, "0").slice(0, 3) || "0", 10);

  if (Number.isNaN(whole) || Number.isNaN(fraction)) {
    throw new Error(`Invalid money value: ${value}`);
  }

  return sign * (whole * 1000 + fraction);
}

export function csvRowToMilliunits(row: { outflow?: unknown; inflow?: unknown; amount?: unknown }): number {
  if (row.amount !== undefined && row.amount !== null && String(row.amount).trim() !== "") {
    return decimalToMilliunits(String(row.amount));
  }

  const outflow = row.outflow === undefined || row.outflow === null ? "" : String(row.outflow).trim();
  const inflow = row.inflow === undefined || row.inflow === null ? "" : String(row.inflow).trim();

  if (outflow) {
    return -Math.abs(decimalToMilliunits(outflow));
  }

  if (inflow) {
    return Math.abs(decimalToMilliunits(inflow));
  }

  return 0;
}

