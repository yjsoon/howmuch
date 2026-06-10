ALTER TABLE transactions ADD COLUMN server_knowledge INTEGER NOT NULL DEFAULT 1;

CREATE INDEX IF NOT EXISTS idx_transactions_plan_server_knowledge
  ON transactions(plan_id, server_knowledge);
