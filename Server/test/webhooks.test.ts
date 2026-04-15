/**
 * Webhook route tests. Verification is skipped in mock mode (no
 * PLAID_CLIENT_ID/SECRET), so these tests focus on the request handling
 * and audit path. Signature verification is covered by the `jose` library's
 * own test suite; we'd need live Plaid JWKs to test the real verification
 * path end-to-end.
 */

// `jose` ships as ESM-only; Jest's default CJS transformer can't parse it.
// We mock it here — the webhook verification logic is still exercised at the
// import-time boundary, but the actual JWT crypto path would need live Plaid
// JWKs to test end-to-end (out of scope for offline unit tests).
jest.mock('jose', () => ({
  importJWK: jest.fn(),
  jwtVerify: jest.fn(),
  decodeProtectedHeader: jest.fn(),
}));
jest.mock('../src/services/database', () => ({
  query: jest.fn(),
}));
jest.mock('../src/services/auditLog', () => ({
  audit: jest.fn().mockResolvedValue(undefined),
  clientIp: jest.fn().mockReturnValue('127.0.0.1'),
}));

// Load in mock mode — no Plaid creds
delete process.env.PLAID_CLIENT_ID;
delete process.env.PLAID_SECRET;
process.env.NODE_ENV = 'test';

import express from 'express';
import request from 'supertest';
import { webhookRouter } from '../src/routes/webhooks';
import { query } from '../src/services/database';
import { audit } from '../src/services/auditLog';

const mockQuery = query as jest.MockedFunction<typeof query>;
const mockAudit = audit as jest.MockedFunction<typeof audit>;

function buildApp(): express.Express {
  const app = express();
  app.use(express.json());
  app.use('/v1/plaid/webhooks', webhookRouter);
  return app;
}

describe('webhook routes (mock mode)', () => {
  beforeEach(() => {
    mockQuery.mockReset();
    mockAudit.mockClear();
    mockQuery.mockResolvedValue({ rows: [], rowCount: 0 } as any);
  });

  test('accepts webhook without verification in mock mode', async () => {
    const res = await request(buildApp())
      .post('/v1/plaid/webhooks')
      .send({
        webhook_type: 'TRANSACTIONS',
        webhook_code: 'DEFAULT_UPDATE',
        item_id: 'item-xyz',
      });

    expect(res.status).toBe(200);
    expect(res.body.received).toBe(true);
  });

  test('looks up user_id by item_id for audit', async () => {
    mockQuery.mockResolvedValueOnce({
      rows: [{ user_id: 'owner-123' }],
      rowCount: 1,
    } as any);

    await request(buildApp()).post('/v1/plaid/webhooks').send({
      webhook_type: 'ITEM',
      webhook_code: 'ERROR',
      item_id: 'item-broken',
    });

    expect(mockQuery).toHaveBeenCalledWith(
      expect.stringMatching(/SELECT user_id FROM plaid_items WHERE item_id/),
      ['item-broken']
    );
    expect(mockAudit).toHaveBeenCalledWith(
      expect.objectContaining({
        userId: 'owner-123',
        action: 'plaid_webhook_received',
        resourceId: 'item-broken',
        detail: { webhook_type: 'ITEM', webhook_code: 'ERROR' },
      })
    );
  });

  test('audits with null userId when item not found', async () => {
    mockQuery.mockResolvedValueOnce({ rows: [], rowCount: 0 } as any);

    await request(buildApp()).post('/v1/plaid/webhooks').send({
      webhook_type: 'TRANSACTIONS',
      webhook_code: 'DEFAULT_UPDATE',
      item_id: 'orphan-item',
    });

    expect(mockAudit).toHaveBeenCalledWith(
      expect.objectContaining({ userId: null, resourceId: 'orphan-item' })
    );
  });

  test.each([
    ['HOLDINGS', 'DEFAULT_UPDATE'],
    ['INVESTMENTS_TRANSACTIONS', 'DEFAULT_UPDATE'],
    ['LIABILITIES', 'DEFAULT_UPDATE'],
  ])('accepts %s/%s webhook and audits it', async (type, code) => {
    mockQuery.mockResolvedValueOnce({
      rows: [{ user_id: 'owner-123' }],
      rowCount: 1,
    } as any);

    const res = await request(buildApp())
      .post('/v1/plaid/webhooks')
      .send({ webhook_type: type, webhook_code: code, item_id: 'inv-1' });

    expect(res.status).toBe(200);
    expect(mockAudit).toHaveBeenCalledWith(
      expect.objectContaining({
        action: 'plaid_webhook_received',
        resourceId: 'inv-1',
        detail: { webhook_type: type, webhook_code: code },
      })
    );
  });

  test('handles unknown webhook_type without crashing', async () => {
    mockQuery.mockResolvedValueOnce({ rows: [], rowCount: 0 } as any);
    const logSpy = jest.spyOn(console, 'log').mockImplementation(() => {});

    const res = await request(buildApp())
      .post('/v1/plaid/webhooks')
      .send({ webhook_type: 'UNKNOWN', webhook_code: 'FOO', item_id: 'i1' });

    expect(res.status).toBe(200);
    logSpy.mockRestore();
  });

  test('returns 200 even when audit/DB throws (Plaid retry safety)', async () => {
    // First call (user lookup) throws — processing must still ack
    mockQuery.mockRejectedValueOnce(new Error('db transient'));
    const errSpy = jest.spyOn(console, 'error').mockImplementation(() => {});

    const res = await request(buildApp())
      .post('/v1/plaid/webhooks')
      .send({ webhook_type: 'TRANSACTIONS', item_id: 'i1' });

    expect(res.status).toBe(200);
    expect(res.body.received).toBe(true);
    errSpy.mockRestore();
  });

  test('rejects with 401 in production mode without verification header', async () => {
    // Re-import the router with production env so verification is required.
    await jest.isolateModulesAsync(async () => {
      process.env.NODE_ENV = 'production';
      process.env.PLAID_CLIENT_ID = 'test-id';
      process.env.PLAID_SECRET = 'test-secret';

      jest.doMock('jose', () => ({
        importJWK: jest.fn(),
        jwtVerify: jest.fn(),
        decodeProtectedHeader: jest.fn(),
      }));
      jest.doMock('../src/services/database', () => ({
        query: jest.fn().mockResolvedValue({ rows: [], rowCount: 0 }),
      }));
      jest.doMock('../src/services/auditLog', () => ({
        audit: jest.fn().mockResolvedValue(undefined),
        clientIp: jest.fn().mockReturnValue('127.0.0.1'),
      }));

      const { webhookRouter: prodRouter } = require('../src/routes/webhooks');
      const app = express();
      app.use(express.json());
      app.use('/v1/plaid/webhooks', prodRouter);

      const errSpy = jest.spyOn(console, 'error').mockImplementation(() => {});
      const res = await request(app)
        .post('/v1/plaid/webhooks')
        .send({ webhook_type: 'TRANSACTIONS', item_id: 'x' });

      expect(res.status).toBe(401);
      expect(res.body.error).toMatch(/verification/i);
      errSpy.mockRestore();

      delete process.env.PLAID_CLIENT_ID;
      delete process.env.PLAID_SECRET;
      process.env.NODE_ENV = 'test';
    });
  });
});
