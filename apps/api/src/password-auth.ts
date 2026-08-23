import { createHash, randomBytes, scrypt as nativeScrypt, timingSafeEqual } from "node:crypto";

export const SCRYPT_PARAMS = { costN: 16384, blockSize: 8, parallelization: 5 } as const;
export const SESSION_SECONDS = 30 * 24 * 60 * 60;

export type StoredCredential = {
  user_id: string;
  username: string;
  kdf: string;
  kdf_version: number;
  cost_n: number;
  block_size: number;
  parallelization: number;
  salt_hex: string;
  hash_hex: string;
};

export type NewSession = ReturnType<typeof newSession>;

export function canonicalUsername(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const username = value.toLowerCase();
  return /^[a-z0-9._-]{3,64}$/.test(username) ? username : null;
}

export function validPassword(value: unknown): value is string {
  return typeof value === "string"
    && Array.from(value).length >= 15
    && Buffer.byteLength(value, "utf8") <= 256;
}

export async function passwordCredential(password: string): Promise<Omit<StoredCredential, "user_id" | "username">> {
  const salt = randomBytes(16);
  const hash = await derive(password, salt, SCRYPT_PARAMS.costN, SCRYPT_PARAMS.blockSize, SCRYPT_PARAMS.parallelization);
  return {
    kdf: "scrypt",
    kdf_version: 1,
    cost_n: SCRYPT_PARAMS.costN,
    block_size: SCRYPT_PARAMS.blockSize,
    parallelization: SCRYPT_PARAMS.parallelization,
    salt_hex: salt.toString("hex"),
    hash_hex: hash.toString("hex"),
  };
}

export async function verifyPassword(password: string, credential: StoredCredential | null): Promise<boolean> {
  const valid = credential && validStored(credential);
  const salt = valid ? Buffer.from(credential.salt_hex, "hex") : Buffer.alloc(16);
  const expected = valid ? Buffer.from(credential.hash_hex, "hex") : Buffer.alloc(32);
  const actual = await derive(password, salt, SCRYPT_PARAMS.costN, SCRYPT_PARAMS.blockSize, SCRYPT_PARAMS.parallelization);
  return !!valid && timingSafeEqual(actual, expected);
}

function validStored(c: StoredCredential): boolean {
  return c.kdf === "scrypt"
    && c.kdf_version === 1
    && c.cost_n === SCRYPT_PARAMS.costN
    && c.block_size === SCRYPT_PARAMS.blockSize
    && c.parallelization === SCRYPT_PARAMS.parallelization
    && /^[0-9a-f]{32}$/.test(c.salt_hex)
    && /^[0-9a-f]{64}$/.test(c.hash_hex);
}

async function derive(password: string, salt: Uint8Array, N: number, r: number, p: number): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    nativeScrypt(password, salt, 32, { N, r, p, maxmem: 64 * 1024 * 1024 }, (error, key) => {
      if (error) reject(error);
      else resolve(key);
    });
  });
}

export function newSession(now = Math.floor(Date.now() / 1000)) {
  const token = randomBytes(32).toString("base64url");
  return { id: randomBytes(16).toString("hex"), token, tokenHash: sha256(token), expiresAt: now + SESSION_SECONDS };
}

export function newPersonalApiToken(now = Math.floor(Date.now() / 1000)) {
  const token = `hm_pat_${randomBytes(32).toString("base64url")}`;
  return {
    id: randomBytes(16).toString("hex"),
    token,
    tokenHash: sha256(token),
    createdAt: now,
  };
}

export function sha256(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

export function safeTokenEqual(actual: string, expected: string): boolean {
  return timingSafeEqual(
    createHash("sha256").update(actual).digest(),
    createHash("sha256").update(expected).digest(),
  );
}
