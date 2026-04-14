/**
 * Plaid route tests — mock-mode only (no Plaid credentials required).
 * DB and auditLog are mocked so tests run offline.
 */

// Mock *before* importing the router so the module captures the mocks
jest.mock('../src/services/database', () => ({
  query: jest.fn(),
}));
jest.mock('../src/services/auditLog', () => ({
  audit: jest.fn().mockResolvedValue(undefined),
  clientIp: jest.fn().mockReturnValue('127.0.0.1'),
}));

// Ensure we load plaid router in mock mode (no PLAID_CLIENT_ID / PLAID_SECRET)
delete process.env.PLAID_CLIENT_ID;
delete process.env.PLAID_SECRET;

import express from 'express';
import request from 'supertest';
import { plaidRouter } from '../src/routes/plaid';
import { query } from '../src/services/database';
import { decryptToken } from '../src/services/tokenEncryption';

const mockQuery = query as jest.MockedFunction<typeof query>;

// Seed a deterministic encryption key for tokenEncryption
beforeAll(() => {
  process.env.PLAID_TOKEN_ENCRYPTION_KEY =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
});

/**
 * Build an Express app that injects a fake authenticated user, then mounts
 * the plaid router. This mirrors how index.ts wires `requireAuth` upstream.
 */
function buildApp(userId = 'test-user-1'): express.Express {
  const app = express();
  app.use(express.json());
  app.use((req, _res, next) => {
    req.user = { userId };
    next();
  });
  app.use('/v1/plaid', plaidRouter);
  return app;
}

describe('plaid routes (mock mode)', () => {
  beforeEach(() => {
    mockQuery.mockReset();
  });

  describe('POST /link-token', () => {
    test('returns a mock link token without hitting Plaid or DB', async () => {
      const res = await request(buildApp()).post('/v1/plaid/link-token').send({});
      expect(res.status).toBe(200);
      expect(res.body.linkToken).toMatch(/^link-sandbox-mock-/);
      expect(res.body.expiration).toBeDefined();
      // Mock mode should not touch the DB
      expect(mockQuery).not.toHaveBeenCalled();
    });
  });

  describe('POST /exchange', () => {
    test('stores an encrypted token and returns item metadata', async () => {
      mockQuery.mockResolvedValueOnce({ rows: [], rowCount: 1 } as any);

      const res = await request(buildApp('user-42'))
        .post('/v1/plaid/exchange')
        .send({ publicToken: 'public-sandbox-fake' });

      expect(res.status).toBe(200);
      expect(res.body.itemId).toMatch(/^mock-item-/);
      expect(res.body.institutionName).toBe('Chase');

      // Verify we inserted into plaid_items with an encrypted blob
      expect(mockQuery).toHaveBeenCalledTimes(1);
      const [sql, params] = mockQuery.mock.calls[0];
      expect(sql).toMatch(/INSERT INTO plaid_items/);
      expect(params?.[0]).toBe('user-42');
      const encryptedBlob = params?.[1] as string;
      expect(encryptedBlob).not.toBe('mock-access-token');
      // The blob must decrypt back to the known mock plaintext
      expect(decryptToken(encryptedBlob)).toBe('mock-access-token');
    });

    test('returns 400 when publicToken is missing', async () => {
      const res = await request(buildApp()).post('/v1/plaid/exchange').send({});
      expect(res.status).toBe(400);
      expect(mockQuery).not.toHaveBeenCalled();
    });

    test('access token is never echoed back to client', async () => {
      mockQuery.mockResolvedValueOnce({ rows: [], rowCount: 1 } as any);
      const res = await request(buildApp())
        .post('/v1/plaid/exchange')
        .send({ publicToken: 'public-sandbox-fake' });

      const body = JSON.stringify(res.body);
      expect(body).not.toContain('mock-access-token');
      expect(body).not.toContain('access_token');
    });
  });

  describe('GET /transactions', () => {
    test('returns 404 when user has no linked Plaid items', async () => {
      mockQuery.mockResolvedValueOnce({ rows: [], rowCount: 0 } as any);
      const res = await request(buildApp()).get('/v1/plaid/transactions');
      expect(res.status).toBe(404);
      expect(res.body.error).toMatch(/no linked account/i);
    });

    test('returns mock transaction data when user has a linked item', async () => {
      // Simulate a prior /exchange created a plaid_items row
      mockQuery.mockResolvedValueOnce({
        rows: [
          {
            access_token_enc: 'irrelevant-in-mock-mode',
            item_id: 'mock-item-1',
            cursor: null,
          },
        ],
        rowCount: 1,
      } as any);

      const res = await request(buildApp()).get('/v1/plaid/transactions');
      expect(res.status).toBe(200);
      expect(Array.isArray(res.body.transactions)).toBe(true);
      expect(Array.isArray(res.body.accounts)).toBe(true);
      expect(res.body.accounts.length).toBe(3);
      expect(res.body.hasMore).toBe(false);
    });
  });
});
