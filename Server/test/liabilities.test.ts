/**
 * Liabilities route tests — mock mode only.
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
import { liabilitiesRouter } from '../src/routes/liabilities';
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
  app.use('/v1/liabilities', liabilitiesRouter);
  return app;
}

describe('liabilities routes (mock mode)', () => {
  beforeEach(() => {
    mockQuery.mockReset();
  });

  test('returns 404 when user has no linked items', async () => {
    mockQuery.mockResolvedValueOnce({ rows: [], rowCount: 0 } as any);
    const res = await request(buildApp()).get('/v1/liabilities');
    expect(res.status).toBe(404);
  });

  test('returns all three kinds (credit / mortgage / student) in mock mode', async () => {
    mockQuery.mockResolvedValueOnce({
      rows: [{ access_token_enc: 'x', item_id: 'mock-item-1' }],
      rowCount: 1,
    } as any);

    const res = await request(buildApp()).get('/v1/liabilities');
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body.credit)).toBe(true);
    expect(Array.isArray(res.body.mortgage)).toBe(true);
    expect(Array.isArray(res.body.student)).toBe(true);
    expect(res.body.credit.length).toBeGreaterThan(0);
    expect(res.body.mortgage.length).toBeGreaterThan(0);
    expect(res.body.student.length).toBeGreaterThan(0);

    // Shape sanity
    expect(res.body.credit[0].aprs).toBeDefined();
    expect(res.body.mortgage[0].interest_rate).toBeDefined();
    expect(res.body.student[0].loan_name).toBeDefined();
  });

  test('accounts carry account_id/type/subtype', async () => {
    mockQuery.mockResolvedValueOnce({
      rows: [{ access_token_enc: 'x', item_id: 'mock-item-1' }],
      rowCount: 1,
    } as any);

    const res = await request(buildApp()).get('/v1/liabilities');
    expect(res.body.accounts.length).toBe(3);
    for (const a of res.body.accounts) {
      expect(a.accountId).toBeDefined();
      expect(a.type).toBeDefined();
    }
  });
});
