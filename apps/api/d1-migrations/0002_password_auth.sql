CREATE TABLE password_credentials (
  user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  username TEXT NOT NULL UNIQUE CHECK (username=lower(username) AND length(username) BETWEEN 3 AND 64 AND username NOT GLOB '*[^a-z0-9._-]*'),
  kdf TEXT NOT NULL DEFAULT 'scrypt' CHECK (kdf='scrypt'), kdf_version INTEGER NOT NULL DEFAULT 1 CHECK (kdf_version=1),
  cost_n INTEGER NOT NULL, block_size INTEGER NOT NULL, parallelization INTEGER NOT NULL,
  salt_hex TEXT NOT NULL CHECK (length(salt_hex)=32 AND salt_hex=lower(salt_hex) AND salt_hex NOT GLOB '*[^0-9a-f]*'),
  hash_hex TEXT NOT NULL CHECK (length(hash_hex)=64 AND hash_hex=lower(hash_hex) AND hash_hex NOT GLOB '*[^0-9a-f]*'),
  created_at INTEGER NOT NULL DEFAULT (unixepoch()), updated_at INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE TABLE auth_setup (singleton INTEGER PRIMARY KEY CHECK (singleton=1), completed_at INTEGER NOT NULL DEFAULT (unixepoch()));
CREATE TABLE login_rate_limits (
  scope TEXT NOT NULL CHECK (scope IN ('username','ip')),
  key_hash TEXT NOT NULL CHECK (length(key_hash)=64 AND key_hash=lower(key_hash) AND key_hash NOT GLOB '*[^0-9a-f]*'),
  window_start INTEGER NOT NULL, attempts INTEGER NOT NULL CHECK (attempts >= 0), PRIMARY KEY(scope,key_hash,window_start)
);
