import { formatAmount, formatMoney } from "../lib/money";
import { formatPeriod } from "../lib/dates";

const WIDTH = 960;
const HEIGHT = 240;
const PAD = { top: 12, right: 8, bottom: 24, left: 64 };

function niceTicks(min: number, max: number): number[] {
  if (min === max) {
    return [min];
  }
  const span = max - min;
  const step = Math.pow(10, Math.floor(Math.log10(span / 3)));
  const rounded = [1, 2, 5, 10].map((m) => m * step).find((s) => span / s <= 4) ?? step;
  const ticks: number[] = [];
  for (let tick = Math.ceil(min / rounded) * rounded; tick <= max; tick += rounded) {
    ticks.push(tick);
  }
  return ticks;
}

function shortMoney(milliunits: number): string {
  const value = milliunits / 1000;
  const abs = Math.abs(value);
  const sign = value < 0 ? "−" : "";
  if (abs >= 1_000_000) return `${sign}${(abs / 1_000_000).toFixed(1)}m`;
  if (abs >= 1_000) return `${sign}${(abs / 1_000).toFixed(abs >= 10_000 ? 0 : 1)}k`;
  return `${sign}${abs.toFixed(0)}`;
}

interface Frame {
  x: (index: number, count: number) => number;
  y: (value: number) => number;
  ticks: number[];
  innerWidth: number;
}

function buildFrame(min: number, max: number): Frame {
  const lo = Math.min(min, 0);
  const hi = Math.max(max, 0);
  const span = hi - lo || 1;
  const innerWidth = WIDTH - PAD.left - PAD.right;
  const innerHeight = HEIGHT - PAD.top - PAD.bottom;
  return {
    x: (index, count) => PAD.left + (innerWidth * (index + 0.5)) / Math.max(count, 1),
    y: (value) => PAD.top + innerHeight * (1 - (value - lo) / span),
    ticks: niceTicks(lo, hi),
    innerWidth,
  };
}

function Gridlines({ frame }: { frame: Frame }) {
  return (
    <g className="chart-grid">
      {frame.ticks.map((tick) => (
        <g key={tick}>
          <line x1={PAD.left} x2={WIDTH - PAD.right} y1={frame.y(tick)} y2={frame.y(tick)} />
          <text x={PAD.left - 8} y={frame.y(tick)} dy="0.32em" textAnchor="end">
            {shortMoney(tick)}
          </text>
        </g>
      ))}
    </g>
  );
}

function XLabels({ labels, frame }: { labels: string[]; frame: Frame }) {
  const every = Math.ceil(labels.length / 10);
  return (
    <g className="chart-axis">
      {labels.map((label, index) =>
        index % every === 0 ? (
          <text
            key={`${label}-${index}`}
            x={frame.x(index, labels.length)}
            y={HEIGHT - 6}
            textAnchor="middle"
          >
            {formatPeriod(label)}
          </text>
        ) : null,
      )}
    </g>
  );
}

/** Paired income/spending columns per period. */
export function PairedColumns({
  periods,
}: {
  periods: Array<{ period: string; income: number; spending: number }>;
}) {
  if (!periods.length) {
    return <EmptyChart />;
  }
  const max = Math.max(...periods.map((p) => Math.max(p.income, p.spending)));
  const frame = buildFrame(0, max);
  const slot = frame.innerWidth / periods.length;
  const bar = Math.min(18, Math.max(3, slot * 0.28));

  return (
    <svg viewBox={`0 0 ${WIDTH} ${HEIGHT}`} className="chart" role="img" aria-label="Income versus spending by period">
      <Gridlines frame={frame} />
      {periods.map((period, index) => {
        const centre = frame.x(index, periods.length);
        return (
          <g key={period.period}>
            <rect
              className="bar-income"
              x={centre - bar - 1}
              width={bar}
              y={frame.y(period.income)}
              height={Math.max(0, frame.y(0) - frame.y(period.income))}
            >
              <title>{`${formatPeriod(period.period)} income ${formatAmount(period.income)}`}</title>
            </rect>
            <rect
              className="bar-spending"
              x={centre + 1}
              width={bar}
              y={frame.y(period.spending)}
              height={Math.max(0, frame.y(0) - frame.y(period.spending))}
            >
              <title>{`${formatPeriod(period.period)} spending ${formatAmount(period.spending)}`}</title>
            </rect>
          </g>
        );
      })}
      <XLabels labels={periods.map((p) => p.period)} frame={frame} />
    </svg>
  );
}

/** Stepped area for net worth over time. */
export function SteppedArea({
  periods,
}: {
  periods: Array<{ period: string; net_worth: number }>;
}) {
  if (!periods.length) {
    return <EmptyChart />;
  }
  const values = periods.map((p) => p.net_worth);
  const frame = buildFrame(Math.min(...values), Math.max(...values));
  const points = periods.map((period, index) => ({
    x: frame.x(index, periods.length),
    y: frame.y(period.net_worth),
  }));

  let path = `M ${points[0].x} ${points[0].y}`;
  for (let index = 1; index < points.length; index += 1) {
    path += ` H ${points[index].x} V ${points[index].y}`;
  }
  const area = `${path} V ${frame.y(0)} H ${points[0].x} Z`;

  return (
    <svg viewBox={`0 0 ${WIDTH} ${HEIGHT}`} className="chart" role="img" aria-label="Net worth over time">
      <Gridlines frame={frame} />
      <path className="area-fill" d={area} />
      <path className="area-line" d={path} />
      {periods.map((period, index) => (
        <circle key={period.period} className="dot" cx={points[index].x} cy={points[index].y} r={2.5}>
          <title>{`${formatPeriod(period.period)} ${formatMoney(period.net_worth)}`}</title>
        </circle>
      ))}
      <XLabels labels={periods.map((p) => p.period)} frame={frame} />
    </svg>
  );
}

/** Dotted line for age of money in days. */
export function DottedLine({
  periods,
}: {
  periods: Array<{ period: string; value: number | null }>;
}) {
  const present = periods.filter((p) => p.value !== null) as Array<{ period: string; value: number }>;
  if (!present.length) {
    return <EmptyChart />;
  }
  const values = present.map((p) => p.value);
  const lo = 0;
  const hi = Math.max(...values);
  const innerHeight = HEIGHT - PAD.top - PAD.bottom;
  const innerWidth = WIDTH - PAD.left - PAD.right;
  const y = (value: number) => PAD.top + innerHeight * (1 - (value - lo) / (hi - lo || 1));
  const x = (index: number) => PAD.left + (innerWidth * (index + 0.5)) / periods.length;
  const ticks = niceTicks(lo, hi);

  const points = periods
    .map((period, index) => (period.value === null ? null : { x: x(index), y: y(period.value), period }))
    .filter((point): point is { x: number; y: number; period: { period: string; value: number | null } } => point !== null);

  const path = points.map((point, index) => `${index === 0 ? "M" : "L"} ${point.x} ${point.y}`).join(" ");

  return (
    <svg viewBox={`0 0 ${WIDTH} ${HEIGHT}`} className="chart" role="img" aria-label="Age of money in days">
      <g className="chart-grid">
        {ticks.map((tick) => (
          <g key={tick}>
            <line x1={PAD.left} x2={WIDTH - PAD.right} y1={y(tick)} y2={y(tick)} />
            <text x={PAD.left - 8} y={y(tick)} dy="0.32em" textAnchor="end">
              {`${Math.round(tick)}d`}
            </text>
          </g>
        ))}
      </g>
      <path className="dotted-line" d={path} />
      {points.map((point) => (
        <circle key={point.period.period} className="dot dot-ink" cx={point.x} cy={point.y} r={3}>
          <title>{`${formatPeriod(point.period.period)} · ${Math.round(point.period.value ?? 0)} days`}</title>
        </circle>
      ))}
      <g className="chart-axis">
        {periods.map((period, index) =>
          index % Math.ceil(periods.length / 10) === 0 ? (
            <text key={period.period} x={x(index)} y={HEIGHT - 6} textAnchor="middle">
              {formatPeriod(period.period)}
            </text>
          ) : null,
        )}
      </g>
    </svg>
  );
}

function EmptyChart() {
  return <div className="chart-empty">No data in this range.</div>;
}
