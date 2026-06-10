PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS schema_migrations (
  version TEXT PRIMARY KEY,
  applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS plans (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  first_month TEXT,
  last_month TEXT,
  date_format_json TEXT NOT NULL DEFAULT '{"format":"DD/MM/YYYY"}',
  currency_format_json TEXT NOT NULL DEFAULT '{"iso_code":"SGD","example_format":"$123,456.78","decimal_digits":2,"decimal_separator":".","symbol_first":true,"group_separator":",","currency_symbol":"$","display_symbol":true}',
  flag_names_json TEXT NOT NULL DEFAULT '{}',
  server_knowledge INTEGER NOT NULL DEFAULT 1,
  external_ynab_id TEXT,
  deleted INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS accounts (
  id TEXT PRIMARY KEY,
  plan_id TEXT NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  type TEXT NOT NULL DEFAULT 'checking',
  on_budget INTEGER NOT NULL DEFAULT 1,
  closed INTEGER NOT NULL DEFAULT 0,
  opening_balance_milli INTEGER NOT NULL DEFAULT 0,
  balance_milli INTEGER NOT NULL DEFAULT 0,
  cleared_balance_milli INTEGER NOT NULL DEFAULT 0,
  uncleared_balance_milli INTEGER NOT NULL DEFAULT 0,
  transfer_payee_id TEXT,
  direct_import_linked INTEGER NOT NULL DEFAULT 0,
  direct_import_in_error INTEGER NOT NULL DEFAULT 0,
  include_in_net_worth INTEGER NOT NULL DEFAULT 1,
  external_ynab_id TEXT,
  deleted INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_accounts_plan_id ON accounts(plan_id);

CREATE TABLE IF NOT EXISTS category_groups (
  id TEXT PRIMARY KEY,
  plan_id TEXT NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  hidden INTEGER NOT NULL DEFAULT 0,
  internal INTEGER NOT NULL DEFAULT 0,
  external_ynab_id TEXT,
  deleted INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_category_groups_plan_id ON category_groups(plan_id);

CREATE TABLE IF NOT EXISTS categories (
  id TEXT PRIMARY KEY,
  plan_id TEXT NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
  category_group_id TEXT REFERENCES category_groups(id),
  name TEXT NOT NULL,
  hidden INTEGER NOT NULL DEFAULT 0,
  internal INTEGER NOT NULL DEFAULT 0,
  external_ynab_id TEXT,
  deleted INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_categories_plan_id ON categories(plan_id);
CREATE INDEX IF NOT EXISTS idx_categories_group_id ON categories(category_group_id);

CREATE TABLE IF NOT EXISTS payees (
  id TEXT PRIMARY KEY,
  plan_id TEXT NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  transfer_account_id TEXT,
  external_ynab_id TEXT,
  deleted INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(plan_id, name)
);

CREATE INDEX IF NOT EXISTS idx_payees_plan_id ON payees(plan_id);

CREATE TABLE IF NOT EXISTS transactions (
  id TEXT PRIMARY KEY,
  plan_id TEXT NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
  account_id TEXT NOT NULL REFERENCES accounts(id),
  date TEXT NOT NULL,
  amount_milli INTEGER NOT NULL,
  memo TEXT,
  cleared TEXT NOT NULL DEFAULT 'uncleared',
  approved INTEGER NOT NULL DEFAULT 0,
  flag_color TEXT,
  flag_name TEXT,
  payee_id TEXT REFERENCES payees(id),
  payee_name_snapshot TEXT,
  category_id TEXT REFERENCES categories(id),
  category_name_snapshot TEXT,
  transfer_account_id TEXT,
  transfer_transaction_id TEXT,
  matched_transaction_id TEXT,
  import_id TEXT,
  import_payee_name TEXT,
  import_payee_name_original TEXT,
  source_kind TEXT,
  source_ref TEXT,
  external_ynab_id TEXT,
  deleted INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_transactions_plan_date ON transactions(plan_id, date);
CREATE INDEX IF NOT EXISTS idx_transactions_account_date ON transactions(account_id, date);
CREATE INDEX IF NOT EXISTS idx_transactions_payee_id ON transactions(payee_id);
CREATE INDEX IF NOT EXISTS idx_transactions_category_id ON transactions(category_id);
CREATE INDEX IF NOT EXISTS idx_transactions_import_id ON transactions(plan_id, import_id);

CREATE TABLE IF NOT EXISTS subtransactions (
  id TEXT PRIMARY KEY,
  transaction_id TEXT NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
  amount_milli INTEGER NOT NULL,
  memo TEXT,
  payee_id TEXT REFERENCES payees(id),
  payee_name_snapshot TEXT,
  category_id TEXT REFERENCES categories(id),
  category_name_snapshot TEXT,
  transfer_account_id TEXT,
  transfer_transaction_id TEXT,
  external_ynab_id TEXT,
  deleted INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_subtransactions_transaction_id ON subtransactions(transaction_id);

CREATE TABLE IF NOT EXISTS source_events (
  id TEXT PRIMARY KEY,
  plan_id TEXT NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
  transaction_id TEXT REFERENCES transactions(id) ON DELETE SET NULL,
  source_kind TEXT NOT NULL,
  source_ref TEXT,
  source_provider TEXT,
  payload_json TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_source_events_transaction_id ON source_events(transaction_id);

CREATE TABLE IF NOT EXISTS import_sessions (
  id TEXT PRIMARY KEY,
  plan_id TEXT REFERENCES plans(id) ON DELETE SET NULL,
  source TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'running',
  started_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  finished_at TEXT,
  summary_json TEXT NOT NULL DEFAULT '{}'
);

CREATE TABLE IF NOT EXISTS import_rows (
  id TEXT PRIMARY KEY,
  import_session_id TEXT NOT NULL REFERENCES import_sessions(id) ON DELETE CASCADE,
  row_index INTEGER NOT NULL,
  status TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  error TEXT,
  transaction_id TEXT REFERENCES transactions(id) ON DELETE SET NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

