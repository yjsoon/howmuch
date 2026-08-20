-- HowMuch-owned target overrides.  The imported YNAB month category remains
-- immutable in ynab_raw_objects; a row with NULL goal_type deliberately hides
-- an imported target, while no row means use the imported target verbatim.
CREATE TABLE IF NOT EXISTS plan_month_category_targets (
  plan_id TEXT NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
  month TEXT NOT NULL CHECK (month GLOB '????-??-??'),
  category_id TEXT NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
  goal_type TEXT NULL CHECK (goal_type IS NULL OR goal_type IN ('TB', 'TBD', 'MF', 'NEED', 'DEBT')),
  goal_target_milli INTEGER NULL CHECK (goal_target_milli IS NULL OR goal_target_milli >= 0),
  goal_target_month TEXT NULL CHECK (goal_target_month IS NULL OR goal_target_month GLOB '????-??-??'),
  source TEXT NOT NULL DEFAULT 'howmuch-local',
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (plan_id, month, category_id)
);

CREATE INDEX IF NOT EXISTS idx_plan_month_category_targets_month
  ON plan_month_category_targets(plan_id, month);
