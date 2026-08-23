import type { Database } from "bun:sqlite";
import type { D1Database } from "./d1";
import type { NewSession, StoredCredential } from "./password-auth";

export type PlanRole = "owner" | "editor" | "viewer";
export type AuthUser = { id: string; username: string; roles: Record<string, PlanRole> };
export type PersonalApiToken = { id: string; name: string; created_at: number; revoked_at: number | null };
export type NewPersonalApiToken = PersonalApiToken & { userId: string; tokenHash: string };
export type SetupInput = {
  userId: string;
  username: string;
  credential: Omit<StoredCredential, "user_id" | "username">;
  session: Pick<NewSession, "id" | "tokenHash" | "expiresAt">;
  planId: string;
};

export interface AuthStore {
  setupRequired(): Promise<boolean>;
  setup(input: SetupInput): Promise<boolean>;
  credential(username: string): Promise<StoredCredential | null>;
  createSession(userId: string, session: Pick<NewSession, "id" | "tokenHash" | "expiresAt">): Promise<void>;
  authenticateSession(tokenHash: string, now: number): Promise<AuthUser | null>;
  revokeSession(tokenHash: string, now: number): Promise<void>;
  listPersonalApiTokens(userId: string): Promise<PersonalApiToken[]>;
  createPersonalApiToken(token: NewPersonalApiToken): Promise<void>;
  revokePersonalApiToken(userId: string, tokenId: string, now: number): Promise<PersonalApiToken | null>;
  authenticatePersonalApiToken(tokenHash: string): Promise<AuthUser | null>;
  rateAttempt(scope: "username" | "ip", keyHash: string, windowStart: number): Promise<number>;
}

const credentialSql = `SELECT user_id,username,kdf,kdf_version,cost_n,block_size,parallelization,salt_hex,hash_hex FROM password_credentials WHERE username=?`;

export class SQLiteAuthStore implements AuthStore {
  constructor(private readonly db: Database) {}

  async setupRequired(): Promise<boolean> {
    return !this.db.query("SELECT 1 FROM auth_setup UNION ALL SELECT 1 FROM users LIMIT 1").get();
  }

  async setup(i: SetupInput) {
    try {
      this.db.run("BEGIN IMMEDIATE");
      if (this.db.query("SELECT 1 FROM auth_setup UNION ALL SELECT 1 FROM users LIMIT 1").get()) {
        this.db.run("ROLLBACK");
        return false;
      }
      this.db.run("INSERT INTO auth_setup(singleton) VALUES(1)");
      this.db.query("INSERT OR IGNORE INTO plans(id,name) VALUES(?,?)").run(i.planId, "My Plan");
      this.db.query("INSERT INTO users(id,display_name) VALUES(?,?)").run(i.userId, i.username);
      insertCredential(this.db, i);
      this.db.query("INSERT INTO plan_memberships(plan_id,user_id,role) VALUES(?,?,'owner')").run(i.planId, i.userId);
      this.db.query("INSERT INTO sessions(id,user_id,token_hash,expires_at) VALUES(?,?,?,?)")
        .run(i.session.id, i.userId, i.session.tokenHash, i.session.expiresAt);
      this.db.run("COMMIT");
      return true;
    } catch (error) {
      if (this.db.inTransaction) this.db.run("ROLLBACK");
      if (/unique|constraint/i.test(String(error))) return false;
      throw error;
    }
  }

  async credential(username: string): Promise<StoredCredential | null> {
    return (this.db.query(credentialSql).get(username) as StoredCredential | null) ?? null;
  }

  async createSession(userId: string, session: Pick<NewSession, "id" | "tokenHash" | "expiresAt">): Promise<void> {
    this.db.query("INSERT INTO sessions(id,user_id,token_hash,expires_at) VALUES(?,?,?,?)")
      .run(session.id, userId, session.tokenHash, session.expiresAt);
  }

  async authenticateSession(tokenHash: string, now: number): Promise<AuthUser | null> {
    const user = this.db.query(
      `SELECT u.id,pc.username
       FROM sessions s
       JOIN users u ON u.id=s.user_id
       JOIN password_credentials pc ON pc.user_id=u.id
       WHERE s.token_hash=? AND s.revoked_at IS NULL AND s.expires_at>?`,
    ).get(tokenHash, now) as { id: string; username: string } | null;
    if (!user) return null;
    const memberships = this.db.query("SELECT plan_id,role FROM plan_memberships WHERE user_id=?").all(user.id);
    return { ...user, roles: roles(memberships as Array<{ plan_id: string; role: PlanRole }>) };
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
    const user = this.db.query(
      `SELECT u.id,pc.username
       FROM personal_api_tokens t
       JOIN users u ON u.id=t.user_id
       JOIN password_credentials pc ON pc.user_id=u.id
       WHERE t.token_hash=? AND t.revoked_at IS NULL`,
    ).get(tokenHash) as { id: string; username: string } | null;
    if (!user) return null;
    const memberships = this.db.query("SELECT plan_id,role FROM plan_memberships WHERE user_id=?").all(user.id);
    return { ...user, roles: roles(memberships as Array<{ plan_id: string; role: PlanRole }>) };
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

function roles(rows: Array<{ plan_id: string; role: PlanRole }>): Record<string, PlanRole> {
  const result = Object.create(null) as Record<string, PlanRole>;
  for (const row of rows) result[row.plan_id] = row.role;
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
        { sql: "INSERT OR IGNORE INTO plans(id,name) VALUES($1,$2)", values: [input.planId, "My Plan"] },
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

  async createSession(userId: string, session: Pick<NewSession, "id" | "tokenHash" | "expiresAt">): Promise<void> {
    await this.db.run(
      "INSERT INTO sessions(id,user_id,token_hash,expires_at) VALUES($1,$2,$3,$4)",
      [session.id, userId, session.tokenHash, session.expiresAt],
    );
  }

  async authenticateSession(tokenHash: string, now: number): Promise<AuthUser | null> {
    const user = await this.db.get<{ id: string; username: string }>(
      `SELECT u.id,pc.username
       FROM sessions s
       JOIN users u ON u.id=s.user_id
       JOIN password_credentials pc ON pc.user_id=u.id
       WHERE s.token_hash=$1 AND s.revoked_at IS NULL AND s.expires_at>$2`,
      [tokenHash, now],
    );
    if (!user) return null;
    const memberships = await this.db.all<{ plan_id: string; role: PlanRole }>(
      "SELECT plan_id,role FROM plan_memberships WHERE user_id=$1",
      [user.id],
    );
    return { ...user, roles: roles(memberships) };
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
    const user = await this.db.get<{ id: string; username: string }>(
      `SELECT u.id,pc.username
       FROM personal_api_tokens t
       JOIN users u ON u.id=t.user_id
       JOIN password_credentials pc ON pc.user_id=u.id
       WHERE t.token_hash=$1 AND t.revoked_at IS NULL`,
      [tokenHash],
    );
    if (!user) return null;
    const memberships = await this.db.all<{ plan_id: string; role: PlanRole }>(
      "SELECT plan_id,role FROM plan_memberships WHERE user_id=$1",
      [user.id],
    );
    return { ...user, roles: roles(memberships) };
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
}
