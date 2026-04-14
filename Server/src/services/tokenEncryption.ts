import crypto from 'crypto';

/**
 * AES-256-GCM encryption for Plaid access tokens at rest.
 *
 * Uses `PLAID_TOKEN_ENCRYPTION_KEY` (64 hex chars = 32 bytes). This key is
 * intentionally separate from `ADMIN_BEARER_TOKEN` so that admin access to
 * the server does NOT grant the ability to decrypt Plaid access tokens — the
 * admin route has no way to obtain or use this key.
 *
 * Wire format: base64( iv[12] || authTag[16] || ciphertext[...] )
 */

const ALGO = 'aes-256-gcm' as const;
const IV_LEN = 12;
const TAG_LEN = 16;

function getKey(): Buffer {
  const hex = process.env.PLAID_TOKEN_ENCRYPTION_KEY;
  if (!hex || hex.length !== 64) {
    throw new Error(
      'PLAID_TOKEN_ENCRYPTION_KEY must be a 64-character hex string (32 bytes)'
    );
  }
  return Buffer.from(hex, 'hex');
}

/**
 * Encrypt a plaintext Plaid access token.
 * Returns a base64-encoded blob safe for TEXT columns.
 */
export function encryptToken(plaintext: string): string {
  const key = getKey();
  const iv = crypto.randomBytes(IV_LEN);
  const cipher = crypto.createCipheriv(ALGO, key, iv);
  const enc = Buffer.concat([
    cipher.update(plaintext, 'utf8'),
    cipher.final(),
  ]);
  const tag = cipher.getAuthTag();
  // Pack: iv || tag || ciphertext
  return Buffer.concat([iv, tag, enc]).toString('base64');
}

/**
 * Decrypt a previously encrypted token blob.
 * Throws on tampered data or wrong key (GCM authentication failure).
 */
export function decryptToken(blob: string): string {
  const key = getKey();
  const buf = Buffer.from(blob, 'base64');
  if (buf.length < IV_LEN + TAG_LEN + 1) {
    throw new Error('Encrypted token blob too short');
  }
  const iv = buf.subarray(0, IV_LEN);
  const tag = buf.subarray(IV_LEN, IV_LEN + TAG_LEN);
  const enc = buf.subarray(IV_LEN + TAG_LEN);
  const decipher = crypto.createDecipheriv(ALGO, key, iv);
  decipher.setAuthTag(tag);
  return decipher.update(enc, undefined, 'utf8') + decipher.final('utf8');
}
