CREATE TABLE rewards_tracker_snapshots (
  plan_id TEXT PRIMARY KEY REFERENCES plans(id) ON DELETE CASCADE,
  payload_json TEXT NOT NULL,
  source_kind TEXT NOT NULL DEFAULT 'rewards-tracker-export',
  imported_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE rewards_tracker_cards (
  plan_id TEXT NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
  id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  name TEXT NOT NULL,
  issuer TEXT NOT NULL,
  type TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (plan_id, id)
);

CREATE INDEX idx_rewards_tracker_cards_plan ON rewards_tracker_cards(plan_id);
CREATE INDEX idx_rewards_tracker_cards_account ON rewards_tracker_cards(plan_id, account_id);
