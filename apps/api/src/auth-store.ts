import type { Database } from "bun:sqlite";
import type { D1Database } from "./d1";
import type { NewSession, StoredCredential } from "./password-auth";
import type { SeedCurrencyFormat, SeedDateFormat } from "./plan-settings-seed";

export type PlanRole = "owner" | "editor" | "viewer";
export type AuthUser = {
  id: string;
  username: string;
  roles: Record<string, PlanRole>;
  /**
   * Unix seconds at which this session stops being accepted, for session
   * principals only. The web client keeps it so it can tell, without asking
   * the server, whether the credential in this browser is still live — it
   * refuses to paint cached ledger data once it is not (#175, #177).
   */
  sessionExpiresAt?: number;
};
export type PersonalApiToken = { id: string; name: string; created_at: number; revoked_at: number | null };
export type NewPersonalApiToken = PersonalApiToken & { userId: string; tokenHash: string };
export type SetupInput = {
  userId: string;
  username: string;
  credential: Omit<StoredCredential, "user_id" | "username">;
  session: Pick<NewSession, "id" | "tokenHash" | "expiresAt">;
  planId: string;
  /** Applied only when the plan row is created here; absent keeps the schema default (SGD). */
  currencyFormat?: SeedCurrencyFormat;
  dateFormat?: SeedDateFormat;
};

export interface AuthStore {
  setupRequired(): Promise<boolean>;
  setup(input: SetupInput): Promise<boolean>;
  credential(username: string): Promise<StoredCredential | null>;
  /**
   * Starts a session only while the stored password hash is still
   * `verifiedHashHex`, the one the caller just checked. A password change that
   * commits between the check and this insert therefore wins, and no session is
   * created (returns false).
   */
  createSession(
    userId: string,
    session: Pick<NewSession, "id" | "tokenHash" | "expiresAt">,
    verifiedHashHex: string,
  ): Promise<boolean>;
  authenticateSession(tokenHash: string, now: number): Promise<AuthUser | null>;
  revokeSession(tokenHash: string, now: number): Promise<void>;
  listPersonalApiTokens(userId: string): Promise<PersonalApiToken[]>;
  createPersonalApiToken(token: NewPersonalApiToken): Promise<void>;
  revokePersonalApiToken(userId: string, tokenId: string, now: number): Promise<PersonalApiToken | null>;
  authenticatePersonalApiToken(tokenHash: string): Promise<AuthUser | null>;
  rateAttempt(scope: "username" | "ip", keyHash: string, windowStart: number): Promise<number>;
  /**
   * Replaces the user's password credential, revokes every session of that
   * user (the caller's included) and starts `session` in its place, in one
   * atomic step. Personal API tokens are separate credentials and are left alone.
   * It applies only while the stored password hash is still `verifiedHashHex`,
   * the one the caller just checked; when another change committed first it
   * changes nothing (no revocation, no session) and returns false.
   */
  replaceCredential(
    userId: string,
    credential: Omit<StoredCredential, "user_id" | "username">,
    session: Pick<NewSession, "id" | "tokenHash" | "expiresAt">,
    now: number,
    verifiedHashHex: string,
  ): Promise<boolean>;
  /** Deletes a bounded batch of expired sessions and long-finished rate-limit windows. Never touches live rows. */
  pruneExpired(now: number): Promise<void>;
}

/** Rows removed per table by one prune, so a backlog is worked off a little at a time. */
const PRUNE_BATCH = 500;
/** A rate-limit window is kept for a day after it ends, long past the 15 minutes it matters for. */
const RATE_LIMIT_WINDOW_SECONDS = 900;
const RATE_LIMIT_RETENTION_SECONDS = 24 * 60 * 60;

// Sessions use `idx_sessions_expiry`. Rate-limit rows have no window index (the
// primary key leads with scope and key), but the table only grows with failed
// or repeated logins and is trimmed here on every successful sign-in, so the
// scan stays small and no migration is needed.
const pruneSessionsSql = (placeholder: string) =>
  `DELETE FROM sessions WHERE id IN (SELECT id FROM sessions WHERE expires_at<${placeholder} LIMIT ${PRUNE_BATCH})`;
const pruneRateLimitsSql = (placeholder: string) =>
  `DELETE FROM login_rate_limits WHERE rowid IN (SELECT rowid FROM login_rate_limits WHERE window_start<${placeholder} LIMIT ${PRUNE_BATCH})`;
const rateLimitCutoff = (now: number) => now - RATE_LIMIT_RETENTION_SECONDS - RATE_LIMIT_WINDOW_SECONDS;

const replaceCredentialSql = (p: (n: number) => string) =>
  `UPDATE password_credentials
   SET kdf=${p(1)},kdf_version=${p(2)},cost_n=${p(3)},block_size=${p(4)},parallelization=${p(5)},salt_hex=${p(6)},hash_hex=${p(7)},updated_at=unixepoch()
   WHERE user_id=${p(8)} AND hash_hex=${p(9)}`;
/** Revokes only once the credential holds the new hash, i.e. this request's own update applied. */
const revokeSessionsSql = (p: (n: number) => string) =>
  `UPDATE sessions SET revoked_at=${p(1)} WHERE user_id=${p(2)} AND revoked_at IS NULL
   AND EXISTS (SELECT 1 FROM password_credentials WHERE user_id=${p(2)} AND hash_hex=${p(3)})`;
/** Inserts only once the credential holds the new hash, i.e. this request's own update applied. */
const insertSessionSql = (p: (n: number) => string) =>
  `INSERT INTO sessions(id,user_id,token_hash,expires_at)
   SELECT ${p(1)},${p(2)},${p(3)},${p(4)}
   WHERE EXISTS (SELECT 1 FROM password_credentials WHERE user_id=${p(2)} AND hash_hex=${p(5)})`;
/** Inserts only while the user's stored hash is still the verified one. */
const insertVerifiedSessionSql = (p: (n: number) => string) =>
  `INSERT INTO sessions(id,user_id,token_hash,expires_at)
   SELECT ${p(1)},${p(2)},${p(3)},${p(4)}
   WHERE EXISTS (SELECT 1 FROM password_credentials WHERE user_id=${p(2)} AND hash_hex=${p(5)})`;
const credentialValues = (userId: string, c: Omit<StoredCredential, "user_id" | "username">, verifiedHashHex: string) =>
  [c.kdf, c.kdf_version, c.cost_n, c.block_size, c.parallelization, c.salt_hex, c.hash_hex, userId, verifiedHashHex];

/** Plan row for first-owner setup; seeded formats go in the same statement, omitted ones keep the schema default. */
function planInsert(input: SetupInput, placeholder: (n: number) => string): { sql: string; values: string[] } {
  const columns = ["id", "name"];
  const values = [input.planId, "My Plan"];
  if (input.currencyFormat) { columns.push("currency_format_json"); values.push(JSON.stringify(input.currencyFormat)); }
  if (input.dateFormat) { columns.push("date_format_json"); values.push(JSON.stringify(input.dateFormat)); }
  return {
    sql: `INSERT OR IGNORE INTO plans(${columns.join(",")}) VALUES(${values.map((_, i) => placeholder(i + 1)).join(",")})`,
    values,
  };
}

const credentialSql = `SELECT user_id,username,kdf,kdf_version,cost_n,block_size,parallelization,salt_hex,hash_hex FROM password_credentials WHERE username=?`;

/**
 * Identity and plan roles in a single statement. The LEFT JOIN keeps a user
 * with no memberships authenticated — they arrive as one row whose plan_id is
 * NULL, which `roles()` skips — so authentication costs one D1 round trip
 * instead of two.
 */
const sessionPrincipalSql = `SELECT u.id,pc.username,pm.plan_id,pm.role,s.expires_at
   FROM sessions s
   JOIN users u ON u.id=s.user_id
   JOIN password_credentials pc ON pc.user_id=u.id
   LEFT JOIN plan_memberships pm ON pm.user_id=u.id
   WHERE s.token_hash=? AND s.revoked_at IS NULL AND s.expires_at>?`;

const tokenPrincipalSql = `SELECT u.id,pc.username,pm.plan_id,pm.role
   FROM personal_api_tokens t
   JOIN users u ON u.id=t.user_id
   JOIN password_credentials pc ON pc.user_id=u.id
   LEFT JOIN plan_memberships pm ON pm.user_id=u.id
   WHERE t.token_hash=? AND t.revoked_at IS NULL`;

/** Row shape both principal queries return, one row per membership. */
type PrincipalRow = { id: string; username: string; plan_id: string | null; role: PlanRole | null; expires_at?: number | null };

function principal(rows: PrincipalRow[]): AuthUser | null {
  const first = rows[0];
  if (!first) return null;
  const user: AuthUser = { id: first.id, username: first.username, roles: roles(rows) };
  // Only the session query selects an expiry; personal API tokens have none.
  if (typeof first.expires_at === "number") {
    user.sessionExpiresAt = Number(first.expires_at);
  }
  return user;
}

export class SQLiteAuthStore implements AuthStore {
  constructor(private readonly db: Database) {}

  async setupRequired(): Promise<boolean> {
    return !this.db.query("SELECT 1 FROM auth_setup UNION ALL SELECT 1 FROM users LIMIT 1").get();
  }

  async setup(i: SetupInput) {
    let began = false;
    try {
      this.db.run("BEGIN IMMEDIATE");
      began = true;
      if (this.db.query("SELECT 1 FROM auth_setup UNION ALL SELECT 1 FROM users LIMIT 1").get()) {
        this.db.run("ROLLBACK");
        return false;
      }
      this.db.run("INSERT INTO auth_setup(singleton) VALUES(1)");
      const plan = planInsert(i, () => "?");
      this.db.query(plan.sql).run(...plan.values);
      this.db.query("INSERT INTO users(id,display_name) VALUES(?,?)").run(i.userId, i.username);
      insertCredential(this.db, i);
      this.db.query("INSERT INTO plan_memberships(plan_id,user_id,role) VALUES(?,?,'owner')").run(i.planId, i.userId);
      this.db.query("INSERT INTO sessions(id,user_id,token_hash,expires_at) VALUES(?,?,?,?)")
        .run(i.session.id, i.userId, i.session.tokenHash, i.session.expiresAt);
      this.db.run("COMMIT");
      return true;
    } catch (error) {
      if (began && this.db.inTransaction) this.db.run("ROLLBACK");
      if (/unique|constraint/i.test(String(error))) return false;
      throw error;
    }
  }

  async credential(username: string): Promise<StoredCredential | null> {
    return (this.db.query(credentialSql).get(username) as StoredCredential | null) ?? null;
  }

  async createSession(
    userId: string,
    session: Pick<NewSession, "id" | "tokenHash" | "expiresAt">,
    verifiedHashHex: string,
  ): Promise<boolean> {
    const inserted = this.db.query(insertVerifiedSessionSql((n) => `?${n}`))
      .run(session.id, userId, session.tokenHash, session.expiresAt, verifiedHashHex);
    return inserted.changes === 1;
  }

  async authenticateSession(tokenHash: string, now: number): Promise<AuthUser | null> {
    return principal(this.db.query(sessionPrincipalSql).all(tokenHash, now) as PrincipalRow[]);
  }

  async revokeSession(tokenHash: string, now: number): Promise<void> {
    this.db.query("UPDATE sessions SET revoked_at=? WHERE token_hash=? AND revoked_at IS NULL").run(now, tokenHash);
  }

  async listPersonalApiTokens(userId: string): Promise<PersonalApiToken[]> {
    return this.db.query(
      "SELECT id,name,created_at,revoked_at FROM personal_api_tokens WHERE user_id=? ORDER BY created_at DESC,id",
    ).all(userId) as PersonalApiToken[];
  }

  async createPersonalApiToken(token: NewPersonalApiToken): Promise<void> {
    this.db.query(
      "INSERT INTO personal_api_tokens(id,user_id,name,token_hash,created_at) VALUES(?,?,?,?,?)",
    ).run(token.id, token.userId, token.name, token.tokenHash, token.created_at);
  }

  async revokePersonalApiToken(userId: string, tokenId: string, now: number): Promise<PersonalApiToken | null> {
    return (this.db.query(
      `UPDATE personal_api_tokens SET revoked_at=COALESCE(revoked_at,?) WHERE id=? AND user_id=?
       RETURNING id,name,created_at,revoked_at`,
    ).get(now, tokenId, userId) as PersonalApiToken | null) ?? null;
  }

  async authenticatePersonalApiToken(tokenHash: string): Promise<AuthUser | null> {
    return principal(this.db.query(tokenPrincipalSql).all(tokenHash) as PrincipalRow[]);
  }

  async rateAttempt(scope: "username" | "ip", keyHash: string, windowStart: number): Promise<number> {
    const row = this.db.query(
      `INSERT INTO login_rate_limits(scope,key_hash,window_start,attempts)
       VALUES(?,?,?,1)
       ON CONFLICT(scope,key_hash,window_start) DO UPDATE SET attempts=attempts+1
       RETURNING attempts`,
    ).get(scope, keyHash, windowStart) as { attempts: number };
    return row.attempts;
  }

  async replaceCredential(
    userId: string,
    credential: Omit<StoredCredential, "user_id" | "username">,
    session: Pick<NewSession, "id" | "tokenHash" | "expiresAt">,
    now: number,
    verifiedHashHex: string,
  ): Promise<boolean> {
    let began = false;
    try {
      this.db.run("BEGIN IMMEDIATE");
      began = true;
      const updated = this.db.query(replaceCredentialSql((n) => `?${n}`))
        .run(...credentialValues(userId, credential, verifiedHashHex));
      if (updated.changes !== 1) {
        this.db.run("ROLLBACK");
        return false;
      }
      this.db.query(revokeSessionsSql((n) => `?${n}`)).run(now, userId, credential.hash_hex);
      this.db.query(insertSessionSql((n) => `?${n}`))
        .run(session.id, userId, session.tokenHash, session.expiresAt, credential.hash_hex);
      this.db.run("COMMIT");
      return true;
    } catch (error) {
      if (began && this.db.inTransaction) this.db.run("ROLLBACK");
      throw error;
    }
  }

  async pruneExpired(now: number): Promise<void> {
    this.db.query(pruneSessionsSql("?")).run(now);
    this.db.query(pruneRateLimitsSql("?")).run(rateLimitCutoff(now));
  }
}

function insertCredential(db: Database, input: SetupInput): void {
  const credential = input.credential;
  db.query(
    `INSERT INTO password_credentials(user_id,username,kdf,kdf_version,cost_n,block_size,parallelization,salt_hex,hash_hex)
     VALUES(?,?,?,?,?,?,?,?,?)`,
  ).run(
    input.userId,
    input.username,
    credential.kdf,
    credential.kdf_version,
    credential.cost_n,
    credential.block_size,
    credential.parallelization,
    credential.salt_hex,
    credential.hash_hex,
  );
}

function roles(rows: Array<{ plan_id: string | null; role: PlanRole | null }>): Record<string, PlanRole> {
  const result = Object.create(null) as Record<string, PlanRole>;
  // The LEFT JOIN emits one NULL-plan row for a user with no memberships.
  for (const row of rows) if (row.plan_id != null && row.role != null) result[row.plan_id] = row.role;
  return result;
}

export class D1AuthStore implements AuthStore {
  constructor(private readonly db: D1Database) {}

  async setupRequired(): Promise<boolean> {
    return !(await this.db.get("SELECT 1 AS present FROM auth_setup UNION ALL SELECT 1 FROM users LIMIT 1"));
  }

  async setup(input: SetupInput): Promise<boolean> {
    const credential = input.credential;
    try {
      await this.db.atomicBatch([
        { sql: "INSERT INTO auth_setup(singleton) VALUES(1)" },
        planInsert(input, (n) => `$${n}`),
        { sql: "INSERT INTO users(id,display_name) VALUES($1,$2)", values: [input.userId, input.username] },
        {
          sql: `INSERT INTO password_credentials(user_id,username,kdf,kdf_version,cost_n,block_size,parallelization,salt_hex,hash_hex)
                VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)`,
          values: [
            input.userId,
            input.username,
            credential.kdf,
            credential.kdf_version,
            credential.cost_n,
            credential.block_size,
            credential.parallelization,
            credential.salt_hex,
            credential.hash_hex,
          ],
        },
        { sql: "INSERT INTO plan_memberships(plan_id,user_id,role) VALUES($1,$2,'owner')", values: [input.planId, input.userId] },
        {
          sql: "INSERT INTO sessions(id,user_id,token_hash,expires_at) VALUES($1,$2,$3,$4)",
          values: [input.session.id, input.userId, input.session.tokenHash, input.session.expiresAt],
        },
      ]);
      return true;
    } catch (error) {
      if (/unique|constraint/i.test(String(error))) return false;
      throw error;
    }
  }

  async credential(username: string): Promise<StoredCredential | null> {
    return this.db.get<StoredCredential>(credentialSql, [username]);
  }

  async createSession(
    userId: string,
    session: Pick<NewSession, "id" | "tokenHash" | "expiresAt">,
    verifiedHashHex: string,
  ): Promise<boolean> {
    const inserted = await this.db.get<{ id: string }>(
      `${insertVerifiedSessionSql((n) => `$${n}`)} RETURNING id`,
      [session.id, userId, session.tokenHash, session.expiresAt, verifiedHashHex],
    );
    return inserted != null;
  }

  async authenticateSession(tokenHash: string, now: number): Promise<AuthUser | null> {
    return principal(await this.db.all<PrincipalRow>(sessionPrincipalSql, [tokenHash, now]));
  }

  async revokeSession(tokenHash: string, now: number): Promise<void> {
    await this.db.run(
      "UPDATE sessions SET revoked_at=$1 WHERE token_hash=$2 AND revoked_at IS NULL",
      [now, tokenHash],
    );
  }

  async listPersonalApiTokens(userId: string): Promise<PersonalApiToken[]> {
    return this.db.all<PersonalApiToken>(
      "SELECT id,name,created_at,revoked_at FROM personal_api_tokens WHERE user_id=$1 ORDER BY created_at DESC,id",
      [userId],
    );
  }

  async createPersonalApiToken(token: NewPersonalApiToken): Promise<void> {
    await this.db.run(
      "INSERT INTO personal_api_tokens(id,user_id,name,token_hash,created_at) VALUES($1,$2,$3,$4,$5)",
      [token.id, token.userId, token.name, token.tokenHash, token.created_at],
    );
  }

  async revokePersonalApiToken(userId: string, tokenId: string, now: number): Promise<PersonalApiToken | null> {
    return this.db.get<PersonalApiToken>(
      `UPDATE personal_api_tokens SET revoked_at=COALESCE(revoked_at,$1) WHERE id=$2 AND user_id=$3
       RETURNING id,name,created_at,revoked_at`,
      [now, tokenId, userId],
    );
  }

  async authenticatePersonalApiToken(tokenHash: string): Promise<AuthUser | null> {
    return principal(await this.db.all<PrincipalRow>(tokenPrincipalSql, [tokenHash]));
  }

  async rateAttempt(scope: "username" | "ip", keyHash: string, windowStart: number): Promise<number> {
    const row = await this.db.get<{ attempts: number }>(
      `INSERT INTO login_rate_limits(scope,key_hash,window_start,attempts)
       VALUES($1,$2,$3,1)
       ON CONFLICT(scope,key_hash,window_start) DO UPDATE SET attempts=attempts+1
       RETURNING attempts`,
      [scope, keyHash, windowStart],
    );
    if (!row) throw new Error("Login rate counter did not return a value");
    return Number(row.attempts);
  }

  async replaceCredential(
    userId: string,
    credential: Omit<StoredCredential, "user_id" | "username">,
    session: Pick<NewSession, "id" | "tokenHash" | "expiresAt">,
    now: number,
    verifiedHashHex: string,
  ): Promise<boolean> {
    // The revoke and the insert are conditional on the credential holding this
    // request's new hash, so a stale request touches no session even though the
    // batch still runs every statement.
    const [updated] = await this.db.atomicBatch([
      { sql: replaceCredentialSql((n) => `$${n}`), values: credentialValues(userId, credential, verifiedHashHex) },
      { sql: revokeSessionsSql((n) => `$${n}`), values: [now, userId, credential.hash_hex] },
      {
        sql: insertSessionSql((n) => `$${n}`),
        values: [session.id, userId, session.tokenHash, session.expiresAt, credential.hash_hex],
      },
    ]);
    return Number(updated?.meta?.changes ?? 0) === 1;
  }

  async pruneExpired(now: number): Promise<void> {
    await this.db.run(pruneSessionsSql("$1"), [now]);
    await this.db.run(pruneRateLimitsSql("$1"), [rateLimitCutoff(now)]);
  }
}
