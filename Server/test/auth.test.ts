/**
 * Auth route tests. The database layer is mocked so these tests run offline.
 */

jest.mock('../src/services/database', () => ({
  query: jest.fn(),
}));
jest.mock('../src/services/auditLog', () => ({
  audit: jest.fn().mockResolvedValue(undefined),
  clientIp: jest.fn().mockReturnValue('127.0.0.1'),
}));

import express from 'express';
import request from 'supertest';
import bcrypt from 'bcrypt';
import jwt from 'jsonwebtoken';
import { authRouter } from '../src/routes/auth';
import { query } from '../src/services/database';
import { audit } from '../src/services/auditLog';

const mockQuery = query as jest.MockedFunction<typeof query>;
const mockAudit = audit as jest.MockedFunction<typeof audit>;

const JWT_SECRET = 'test-jwt-secret';
const JWT_REFRESH_SECRET = 'test-refresh-secret';

function buildApp(): express.Express {
  const app = express();
  app.use(express.json());
  app.use('/v1/auth', authRouter);
  return app;
}

describe('auth routes', () => {
  beforeAll(() => {
    process.env.JWT_SECRET = JWT_SECRET;
    process.env.JWT_REFRESH_SECRET = JWT_REFRESH_SECRET;
  });

  beforeEach(() => {
    mockQuery.mockReset();
    mockAudit.mockClear();
  });

  // -------------------------------------------------------------------------
  // POST /register
  // -------------------------------------------------------------------------

  describe('POST /register', () => {
    test('creates a new user and returns tokens', async () => {
      // 1) Lookup returns empty (no duplicate)
      mockQuery.mockResolvedValueOnce({ rows: [], rowCount: 0 } as any);
      // 2) Insert returns new user id
      mockQuery.mockResolvedValueOnce({
        rows: [{ id: 'new-user-id' }],
        rowCount: 1,
      } as any);

      const res = await request(buildApp())
        .post('/v1/auth/register')
        .send({ email: 'test@example.com', password: 'secret12345' });

      expect(res.status).toBe(201);
      expect(res.body.accessToken).toBeDefined();
      expect(res.body.refreshToken).toBeDefined();
      expect(res.body.expiresIn).toBe(900);

      const decoded = jwt.verify(res.body.accessToken, JWT_SECRET) as any;
      expect(decoded.userId).toBe('new-user-id');

      expect(mockAudit).toHaveBeenCalledWith(
        expect.objectContaining({
          userId: 'new-user-id',
          action: 'register',
          resourceType: 'user',
        })
      );
    });

    test('returns 409 when email already registered', async () => {
      mockQuery.mockResolvedValueOnce({
        rows: [{ id: 'existing' }],
        rowCount: 1,
      } as any);

      const res = await request(buildApp())
        .post('/v1/auth/register')
        .send({ email: 'taken@example.com', password: 'secret12345' });

      expect(res.status).toBe(409);
      expect(res.body.error).toMatch(/already registered/i);
      expect(mockAudit).not.toHaveBeenCalled();
    });

    test('returns 400 for invalid email', async () => {
      const res = await request(buildApp())
        .post('/v1/auth/register')
        .send({ email: 'not-an-email', password: 'secret12345' });
      expect(res.status).toBe(400);
    });

    test('returns 400 for password shorter than 8 chars', async () => {
      const res = await request(buildApp())
        .post('/v1/auth/register')
        .send({ email: 'ok@example.com', password: 'short' });
      expect(res.status).toBe(400);
    });

    test('password is bcrypt-hashed before insert', async () => {
      mockQuery.mockResolvedValueOnce({ rows: [], rowCount: 0 } as any);
      mockQuery.mockResolvedValueOnce({
        rows: [{ id: 'u1' }],
        rowCount: 1,
      } as any);

      await request(buildApp())
        .post('/v1/auth/register')
        .send({ email: 'x@example.com', password: 'plaintext-password' });

      const insertCall = mockQuery.mock.calls[1];
      const hashedPassword = insertCall[1]?.[1] as string;
      expect(hashedPassword).not.toBe('plaintext-password');
      expect(hashedPassword).toMatch(/^\$2[aby]\$/); // bcrypt format
      expect(await bcrypt.compare('plaintext-password', hashedPassword)).toBe(true);
    });
  });

  // -------------------------------------------------------------------------
  // POST /login
  // -------------------------------------------------------------------------

  describe('POST /login', () => {
    test('returns tokens on valid credentials', async () => {
      const hash = await bcrypt.hash('correctpw', 4);
      mockQuery.mockResolvedValueOnce({
        rows: [{ id: 'user-1', password_hash: hash }],
        rowCount: 1,
      } as any);

      const res = await request(buildApp())
        .post('/v1/auth/login')
        .send({ email: 'user@example.com', password: 'correctpw' });

      expect(res.status).toBe(200);
      expect(res.body.accessToken).toBeDefined();
      const decoded = jwt.verify(res.body.accessToken, JWT_SECRET) as any;
      expect(decoded.userId).toBe('user-1');

      expect(mockAudit).toHaveBeenCalledWith(
        expect.objectContaining({ action: 'login', userId: 'user-1' })
      );
    });

    test('returns 401 for nonexistent email (no leak)', async () => {
      mockQuery.mockResolvedValueOnce({ rows: [], rowCount: 0 } as any);

      const res = await request(buildApp())
        .post('/v1/auth/login')
        .send({ email: 'missing@example.com', password: 'whatever' });

      expect(res.status).toBe(401);
      expect(res.body.error).toBe('Invalid credentials');
      // Must not reveal whether the email existed
      expect(res.body).not.toHaveProperty('reason');
    });

    test('returns 401 for wrong password and audits the failure', async () => {
      const hash = await bcrypt.hash('correctpw', 4);
      mockQuery.mockResolvedValueOnce({
        rows: [{ id: 'user-2', password_hash: hash }],
        rowCount: 1,
      } as any);

      const res = await request(buildApp())
        .post('/v1/auth/login')
        .send({ email: 'user@example.com', password: 'wrongpw' });

      expect(res.status).toBe(401);
      expect(mockAudit).toHaveBeenCalledWith(
        expect.objectContaining({
          userId: 'user-2',
          action: 'login_failed',
          detail: { reason: 'wrong_password' },
        })
      );
    });
  });

  // -------------------------------------------------------------------------
  // POST /refresh
  // -------------------------------------------------------------------------

  describe('POST /refresh', () => {
    test('issues new token pair for valid refresh token', async () => {
      const refreshToken = jwt.sign({ userId: 'user-3' }, JWT_REFRESH_SECRET, {
        expiresIn: '7d',
      });
      mockQuery.mockResolvedValueOnce({
        rows: [{ id: 'user-3' }],
        rowCount: 1,
      } as any);

      const res = await request(buildApp())
        .post('/v1/auth/refresh')
        .send({ refreshToken });

      expect(res.status).toBe(200);
      expect(res.body.accessToken).toBeDefined();
      expect(res.body.refreshToken).toBeDefined();
    });

    test('rejects refresh token signed with wrong secret', async () => {
      const badToken = jwt.sign({ userId: 'user-3' }, 'wrong-secret', {
        expiresIn: '7d',
      });

      const res = await request(buildApp())
        .post('/v1/auth/refresh')
        .send({ refreshToken: badToken });

      expect(res.status).toBe(401);
    });

    test('rejects refresh token for deleted user', async () => {
      const refreshToken = jwt.sign({ userId: 'deleted-user' }, JWT_REFRESH_SECRET, {
        expiresIn: '7d',
      });
      mockQuery.mockResolvedValueOnce({ rows: [], rowCount: 0 } as any);

      const res = await request(buildApp())
        .post('/v1/auth/refresh')
        .send({ refreshToken });

      expect(res.status).toBe(401);
    });

    test('rejects expired refresh token', async () => {
      const expired = jwt.sign({ userId: 'u' }, JWT_REFRESH_SECRET, {
        expiresIn: '-1s',
      });

      const res = await request(buildApp())
        .post('/v1/auth/refresh')
        .send({ refreshToken: expired });

      expect(res.status).toBe(401);
    });

    test('rejects missing refresh token with 400', async () => {
      const res = await request(buildApp()).post('/v1/auth/refresh').send({});
      expect(res.status).toBe(400);
      expect(res.body.error).toMatch(/required/i);
    });
  });
});
