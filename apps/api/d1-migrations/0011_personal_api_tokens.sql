CREATE TABLE personal_api_tokens (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 64 AND name = trim(name)),
  token_hash TEXT NOT NULL UNIQUE CHECK (length(token_hash)=64 AND token_hash=lower(token_hash) AND token_hash NOT GLOB '*[^0-9a-f]*'),
  revoked_at INTEGER,
  created_at INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE INDEX idx_personal_api_tokens_user
  ON personal_api_tokens(user_id, created_at DESC);
