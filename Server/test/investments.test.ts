/**
 * Investments route tests — mock mode only.
 * Mirrors test/plaid.test.ts: mocks DB + auditLog, forces mock mode by
 * unsetting PLAID_CLIENT_ID / PLAID_SECRET before the router is imported.
 */

jest.mock('../src/services/database', () => ({
  query: jest.fn(),
}));
jest.mock('../src/services/auditLog', () => ({
  audit: jest.fn().mockResolvedValue(undefined),
  clientIp: jest.fn().mockReturnValue('127.0.0.1'),
}));

delete process.env.PLAID_CLIENT_ID;
delete process.env.PLAID_SECRET;

import express from 'express';
import request from 'supertest';
import { investmentsRouter } from '../src/routes/investments';
import { query } from '../src/services/database';

const mockQuery = query as jest.MockedFunction<typeof query>;

beforeAll(() => {
  process.env.PLAID_TOKEN_ENCRYPTION_KEY =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
});

function buildApp(userId = 'test-user-1'): express.Express {
  const app = express();
  app.use(express.json());
  app.use((req, _res, next) => {
    req.user = { userId };
    next();
  });
  app.use('/v1/investments', investmentsRouter);
  return app;
}

describe('investments routes (mock mode)', () => {
  beforeEach(() => {
    mockQuery.mockReset();
  });

  describe('GET /holdings', () => {
    test('returns 404 when user has no linked items', async () => {
      mockQuery.mockResolvedValueOnce({ rows: [], rowCount: 0 } as any);
      const res = await request(buildApp()).get('/v1/investments/holdings');
      expect(res.status).toBe(404);
    });

    test('returns mock holdings with securities and accounts', async () => {
      mockQuery.mockResolvedValueOnce({
        rows: [{ access_token_enc: 'x', item_id: 'mock-item-1' }],
        rowCount: 1,
      } as any);

      const res = await request(buildApp()).get('/v1/investments/holdings');
      expect(res.status).toBe(200);
      expect(Array.isArray(res.body.holdings)).toBe(true);
      expect(res.body.holdings.length).toBeGreaterThan(0);
      expect(Array.isArray(res.body.securities)).toBe(true);
      expect(Array.isArray(res.body.accounts)).toBe(true);

      // Holdings should reference known securities/accounts
      const secIds = new Set(res.body.securities.map((s: any) => s.securityId));
      for (const h of res.body.holdings) {
        expect(secIds.has(h.securityId)).toBe(true);
        expect(typeof h.quantity).toBe('number');
      }
    });
  });

  describe('GET /transactions', () => {
    test('returns 404 when user has no linked items', async () => {
      mockQuery.mockResolvedValueOnce({ rows: [], rowCount: 0 } as any);
      const res = await request(buildApp()).get('/v1/investments/transactions');
      expect(res.status).toBe(404);
    });

    test('returns mock investment transactions', async () => {
      mockQuery.mockResolvedValueOnce({
        rows: [
          {
            access_token_enc: 'x',
            item_id: 'mock-item-1',
            investments_last_synced_date: null,
          },
        ],
        rowCount: 1,
      } as any);

      const res = await request(buildApp()).get('/v1/investments/transactions');
      expect(res.status).toBe(200);
      expect(Array.isArray(res.body.transactions)).toBe(true);
      expect(res.body.transactions.length).toBeGreaterThan(0);

      // Every txn must carry the fields the iOS model needs
      for (const t of res.body.transactions) {
        expect(t.investmentTransactionId).toBeDefined();
        expect(t.accountId).toBeDefined();
        expect(t.date).toMatch(/^\d{4}-\d{2}-\d{2}$/);
        expect(t.type).toBeDefined();
      }
    });

    test('does not leak access tokens in response body', async () => {
      mockQuery.mockResolvedValueOnce({
        rows: [
          {
            access_token_enc: 'should-never-leak',
            item_id: 'mock-item-1',
            investments_last_synced_date: null,
          },
        ],
        rowCount: 1,
      } as any);

      const res = await request(buildApp()).get('/v1/investments/transactions');
      const body = JSON.stringify(res.body);
      expect(body).not.toContain('access_token');
      expect(body).not.toContain('should-never-leak');
    });
  });
});
