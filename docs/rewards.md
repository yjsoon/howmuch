# Using HowMuch instead of Rewards Tracker

The compatibility reference is the **web app** in
[`yjsoon/ynab-rewards-tracker`](https://github.com/yjsoon/ynab-rewards-tracker/tree/60cd90ab8c44c4507515f56364ec00d0c97784d2/apps/web),
not its Expo client. HowMuch uses the same reward calculation rules against its own ledger.

## Import configuration separately from ledger history

1. Export settings from Rewards Tracker web.
2. In HowMuch, open **Settings → Rewards import** (native: **Rewards → Import / export**).
3. Export the existing HowMuch configuration before replacing it, then import the tracker JSON.
4. Check linked account names, rates, flag categories and spend tiers. HowMuch can track open on-budget checking/debit accounts as well as credit accounts.
5. Open Rewards at a known historical date and compare the card periods, qualifying spend and rewards.

Import replaces the reward card set. Omitted cards are removed; an empty `cards` array removes all cards. Configuration exports exclude credentials and cached transactions. They do not back up the ledger. A normal tracker settings export has no transactions, so ledger migration must already be complete. No recurring YNAB connection is enabled by importing rewards.

Older cache dumps are supported: explicit null metadata clears prior values, omitted metadata retains it, deleted transactions remain deleted, and name-only categories retain enough information to distinguish purchase refunds from income. Legacy points configurations migrate to miles without replacing explicit modern zero/null rates.

## Read the board at the right date

The default board evaluates each card in **its own reward period**, as of today in Asia/Singapore. A billing card, calendar card and quarterly card can legitimately show different start/end dates. Choose an as-of date to inspect a prior state. Future purchases are not counted as earned rewards.

Historical transaction ranges retain earlier spending in the same cycle when determining minimums, tier rates and cap use. Only the selected transactions contribute to range totals. Full-period context is shown separately; do not add those context totals to the range totals.

Capped cards stay accessible. An available higher spending tier is distinct from a final cap. Featured/hidden/order controls affect presentation, not reward calculation. Device-local display preferences are not a substitute for the portable configuration backup.

## Reward configuration semantics

- **Cashback** is a percentage; **miles** is miles per currency unit. Miles valuation converts miles to a comparison value, not a currency exchange rate. Zero valuation is valid.
- **Earning blocks** round each transaction's eligible spend down. $12 at 4 miles/$ with $5 blocks earns 40 miles. Two $4 transactions earn nothing; they do not combine into a block.
- **Minimum spend** unlocks rewards retroactively. It is not a deductible. A zero or unconfigured minimum imposes no requirement.
- **Maximum spend** caps eligible spending, not the reward amount. Zero or unconfigured maximum means unlimited. Card and category caps allocate chronologically by date and transaction ID; unused partial-block headroom may be unusable.
- **Flag categories** replace the base rate. Unmatched flags use an active unflagged/default rule if one exists. Disabled categories and excluded categories are different. A zero-rate nonexcluded category can still qualify toward a minimum.
- **Enable flag subcategories** is independent of the retained rule definitions. Saving an unrelated edit does not enable disabled rules.
- **Spending tiers** revalue the whole period at the reached rate. Caps use the next threshold being approached when another tier exists. Category rate/cap overrides are supported. These are not marginal tax-style bands.
- **Periods** include calendar months, billing days 1–31 (clamped to month length), promotions, and anchored repeating windows of 2–24 months. Active repeating periods take precedence over promotions/billing.
- When an anchored period starts partway through a previous calendar, billing or promotional window, the old window ends the day before the anchor. Its purchases retain the old qualification rules; purchases on the anchor start the new window.
- **Monthly qualification** can be pending, met or failed. A completed month below the minimum fails the reward period; exceeding the target in a later month does not repair it. Categorized purchase refunds reduce monthly qualification. Ordinary rewards/tier totals retain the source app's outflow-only behavior.

Merchant restrictions are not automatic merchant/MCC matching. They must be represented by the appropriate transaction flags. Imported or AI-proposed explanatory notes do not create executable merchant predicates.

## Optional AI tools require review

**Settings → Reward terms** accepts pasted bank terms or a supported bank URL,
your provider key and exact model ID. Review the generated categories, caps and
tiers before saving. Saving changes only the proposed reward fields on the selected
card. URL fetching rejects redirects and PDFs; paste their text instead.

**Settings → Statement formatter** accepts statement images, extracts editable
transaction rows, and exports CSV. It does not write to the ledger. You can append
or replace rows and cancel between images; completed rows remain available.

Both tools require explicit consent before sending data to the selected provider.
Keys stay in page/request memory, not configuration exports. Provider billing and
retention policies apply; cancellation cannot recall a request already sent.

## Verify against the pinned web source

The differential harness reads only synthetic data and makes no network requests:

```sh
bun scripts/verify-rewards-tracker-parity.ts /path/to/ynab-rewards-tracker
```

Use the pinned reference above. The 19 scenarios cover calendar/billing boundaries, short-month billing dates, blocks, exact minimum boundaries, exclusions/defaults, category caps, tier overrides, promotions, future anchors, refunds and valuation zero. Run under both `TZ=Asia/Singapore` and another server timezone to catch date shifts.

Shared regression checks:

```sh
bun test apps/api/src/rewards apps/api/src/importers/rewards-tracker.test.ts
bun test apps/api/tests/api.test.ts apps/api/tests/d1.test.ts
bun run --cwd apps/web build
```

Native changes also require the repository's Xcode workflow on a selected Mac. Browser rendering or Swift syntax parsing does not substitute for a native build/test run. Live AI-provider checks need explicit authorization and a supplied provider key; mocked tests are not live-provider evidence.

## Deliberate boundaries

HowMuch's authenticated server-backed ledger replaces the tracker's device-local storage architecture; mnemonic cloud backup and recurring YNAB sync are not duplicated. The tracker's feature-flagged recommendation themes and old `/api/agent/rewards` integration are not drop-in HowMuch endpoints. Imported legacy rules/theme records are retained for portability, not a promise that obsolete web routes or external automations are emulated. The [API contract](api-contract.md) describes the supported rewards reporting interface.
