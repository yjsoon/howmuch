# HowMuch Web — Frontend Brief

## Purpose

A quiet, dense, report-first dashboard for a single user's self-hosted ledger. It is a working tool, not a marketing page: the four Reflect-style reports are the product, with transaction drill-down underneath and a mobile quick-entry fallback for capturing spends on the go.

## Non-Goals

- No envelope budgeting, monthly assignment, targets, or YNAB credit-card handling.
- No onboarding, marketing, or empty-state theatre.
- No multi-user auth UI (version one is a single bearer token).

## Design Language: Editorial Ledger

The aesthetic is a broadsheet ledger: ink on paper, hairline rules, controlled density.

- **Palette**: warm paper background (`#f7f5ef`), near-black ink (`#1c1b18`), ledger red (`#a8322a`) for outflows/negatives, racing green (`#2a6648`) for inflows/positives, muted graphite for chrome. One surface, no cards-on-cards.
- **Typography**: Newsreader (serif) for the masthead and report titles; IBM Plex Sans for UI copy; IBM Plex Mono with tabular numerals for every figure. Fonts are bundled via `@fontsource` so the app works offline/self-hosted with no external requests.
- **Density**: compact tables, 13–14px body, generous column alignment rather than whitespace. Right-aligned numerals everywhere.
- **Charts**: hand-rolled SVG (no chart library). Horizontal share bars for breakdowns, paired columns for income vs spending, stepped area for net worth, dotted line for age of money. Quiet by default; detail on hover.
- **Copy**: British spelling throughout (Uncategorised, colour, summarise).

## Stack

- Vite + React 19 + TypeScript, as the `apps/web` workspace (Bun workspaces at the repo root).
- `react-router-dom` for routing; filters live in the URL search string so every report view is linkable and refresh-safe.
- No state library and no fetch library: a small typed API client (`src/api/client.ts`) plus a `useApi` hook with in-flight de-duplication.
- Dev server proxies `/api` and `/v1` to the Bun API on `:8787` (`vite.config.ts`), so there is no CORS story. Production build is a static bundle the API (or any static server) can host.

## Information Architecture

```
┌──────────────────────────────────────────────────────────────┐
│ HOWMUCH        Spending · Income v Spending · Net Worth ·     │
│                Age of Money · Transactions          [+ Add]   │
├──────────────────────────────────────────────────────────────┤
│ Filter rail: date-range presets (1m/3m/12m/YTD/All/custom),   │
│ accounts multi-select, categories multi-select, interval      │
│ segmented control where the report supports it                │
├──────────────────────────────────────────────────────────────┤
│ Report body: summary figures → chart → dense table            │
└──────────────────────────────────────────────────────────────┘
```

### Routes

| Route | View |
| --- | --- |
| `/` | redirect to `/spending` |
| `/spending` | Spending Breakdown: total, share bars per category grouped by category group, click-through to filtered transactions |
| `/income` | Income vs Spending: paired columns per period, table with income / spending / net / cumulative net |
| `/net-worth` | Net Worth: stepped area chart, per-account balance table per period, account filter |
| `/age-of-money` | Age of Money: line of weighted age in days per period, unmatched-spending diagnostics |
| `/transactions` | Dense register with the same filter rail, payee/memo search, drill-down target for every report |
| `/add` | Mobile quick entry: thumb-reach form (amount keypad-first, account, payee, optional category/memo), posts to `/api/mobile/quick-entry` with a client-generated `client_id` for idempotency |

### Filter model

One `Filters` object serialised to the query string and shared by all report routes:

- `from`, `to` (ISO dates; presets compute them client-side)
- `account_ids`, `category_ids` (comma-separated, matching the API)
- `interval` (`day | week | month | year`) where the report supports it

Navigating between tabs preserves the query string, so a date range chosen on Spending carries to Net Worth. Drill-down from a report row links to `/transactions` with the relevant `category_ids`/date range applied.

## Data Layer

The API returns YNAB-style `{ data: ... }` envelopes; amounts are integer milliunits. The client unwraps envelopes and keeps milliunits internal — `formatMoney` (in `src/lib/money.ts`) converts to decimal only at render, honouring the plan's currency settings from `/v1/plans/{id}/settings`.

Endpoints consumed:

- `GET /api/reports/spending-breakdown | income-vs-spending | net-worth | age-of-money`
- `GET /v1/plans/{id}/accounts`, `/categories`, `/payees`, `/settings` (filter options and formatting)
- `GET /v1/plans/{id}/transactions` (+ scoped variants) for the register
- `POST /api/mobile/quick-entry` for quick entry
- `PATCH /v1/plans/{id}/transactions/{id}` for inline edits later

## Directory Sketch

```
apps/web/
  index.html
  vite.config.ts
  package.json
  src/
    main.tsx            # router + app shell
    app.css             # tokens, typography, layout primitives
    api/client.ts       # typed fetch wrapper, envelope unwrap
    api/types.ts        # mirrors apps/api response shapes
    lib/money.ts        # milliunits ↔ display
    lib/dates.ts        # range presets, period labels
    state/filters.ts    # URL ↔ Filters codec, hook
    components/         # FilterRail, SegmentedControl, MultiSelect,
                        # DataTable, charts/ (ShareBars, Columns, Area, Line)
    pages/              # Spending, Income, NetWorth, AgeOfMoney,
                        # Transactions, QuickEntry
```

## Open Questions (for later, not blockers)

- Where the production bundle is served from (API static route vs separate static host).
- Whether the web app needs the bearer token UI now, or whether same-host deployment makes it moot.
- Payee management (rename/merge) — deferred until reports and register are solid.
