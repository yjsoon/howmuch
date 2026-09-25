-- Local assignments intentionally overlay, rather than alter, the immutable
-- YNAB source mirror. A later source sync can update its raw values without
-- erasing a user's switched-over Plan decision.
CREATE TABLE IF NOT EXISTS plan_month_assignments (
  plan_id TEXT NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
  month TEXT NOT NULL CHECK (month GLOB '????-??-??'),
  category_id TEXT NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
  budgeted_milli INTEGER NOT NULL,
  source TEXT NOT NULL DEFAULT 'howmuch-local',
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (plan_id, month, category_id)
);

CREATE INDEX IF NOT EXISTS idx_plan_month_assignments_month
  ON plan_month_assignments(plan_id, month);
