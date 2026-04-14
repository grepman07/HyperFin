import crypto from 'crypto';

// Set env var BEFORE importing the module
const TEST_KEY = crypto.randomBytes(32).toString('hex');
process.env.PLAID_TOKEN_ENCRYPTION_KEY = TEST_KEY;

import { encryptToken, decryptToken } from '../src/services/tokenEncryption';

describe('tokenEncryption', () => {
  const plaintext = 'access-sandbox-abc123-test-token';

  it('round-trips encrypt → decrypt', () => {
    const encrypted = encryptToken(plaintext);
    const decrypted = decryptToken(encrypted);
    expect(decrypted).toBe(plaintext);
  });

  it('produces different ciphertext each time (random IV)', () => {
    const a = encryptToken(plaintext);
    const b = encryptToken(plaintext);
    expect(a).not.toBe(b);
  });

  it('produces a base64 string', () => {
    const encrypted = encryptToken(plaintext);
    // Should be valid base64
    expect(() => Buffer.from(encrypted, 'base64')).not.toThrow();
    expect(encrypted).toMatch(/^[A-Za-z0-9+/=]+$/);
  });

  it('throws on tampered ciphertext', () => {
    const encrypted = encryptToken(plaintext);
    const buf = Buffer.from(encrypted, 'base64');
    // Flip a byte in the ciphertext portion
    buf[buf.length - 1] ^= 0xff;
    const tampered = buf.toString('base64');
    expect(() => decryptToken(tampered)).toThrow();
  });

  it('throws on truncated blob', () => {
    expect(() => decryptToken('dG9vc2hvcnQ=')).toThrow('too short');
  });

  it('throws if encryption key is missing', () => {
    const saved = process.env.PLAID_TOKEN_ENCRYPTION_KEY;
    delete process.env.PLAID_TOKEN_ENCRYPTION_KEY;
    expect(() => encryptToken('test')).toThrow('PLAID_TOKEN_ENCRYPTION_KEY');
    process.env.PLAID_TOKEN_ENCRYPTION_KEY = saved;
  });

  it('throws if encryption key is wrong length', () => {
    const saved = process.env.PLAID_TOKEN_ENCRYPTION_KEY;
    process.env.PLAID_TOKEN_ENCRYPTION_KEY = 'tooshort';
    expect(() => encryptToken('test')).toThrow('64-character hex');
    process.env.PLAID_TOKEN_ENCRYPTION_KEY = saved;
  });

  it('decryption fails with a different key', () => {
    const encrypted = encryptToken(plaintext);
    // Swap in a different key
    const otherKey = crypto.randomBytes(32).toString('hex');
    process.env.PLAID_TOKEN_ENCRYPTION_KEY = otherKey;
    expect(() => decryptToken(encrypted)).toThrow();
    // Restore
    process.env.PLAID_TOKEN_ENCRYPTION_KEY = TEST_KEY;
  });
});
