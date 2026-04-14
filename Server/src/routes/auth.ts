import { Router, Request, Response } from 'express';
import { z } from 'zod';
import bcrypt from 'bcrypt';
import jwt from 'jsonwebtoken';
import { query } from '../services/database';
import { audit, clientIp } from '../services/auditLog';

export const authRouter = Router();

// ---------------------------------------------------------------------------
// Validation schemas
// ---------------------------------------------------------------------------

const RegisterSchema = z.object({
  email: z.string().email().max(255),
  password: z.string().min(8).max(128),
});

const LoginSchema = z.object({
  email: z.string().email(),
  password: z.string(),
});

const RefreshSchema = z.object({
  refreshToken: z.string().min(1),
});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const BCRYPT_ROUNDS = 12;
const ACCESS_EXPIRY = '15m';
const REFRESH_EXPIRY = '7d';

function signTokens(userId: string): { accessToken: string; refreshToken: string; expiresIn: number } {
  const jwtSecret = process.env.JWT_SECRET!;
  const jwtRefreshSecret = process.env.JWT_REFRESH_SECRET!;

  const accessToken = jwt.sign({ userId }, jwtSecret, { expiresIn: ACCESS_EXPIRY });
  const refreshToken = jwt.sign({ userId }, jwtRefreshSecret, { expiresIn: REFRESH_EXPIRY });

  return { accessToken, refreshToken, expiresIn: 900 }; // 15 min in seconds
}

// ---------------------------------------------------------------------------
// POST /v1/auth/register
// ---------------------------------------------------------------------------

authRouter.post('/register', async (req: Request, res: Response) => {
  try {
    const { email, password } = RegisterSchema.parse(req.body);

    // Check for existing user
    const existing = await query('SELECT id FROM users WHERE email = $1', [email]);
    if (existing.rows.length > 0) {
      res.status(409).json({ error: 'Email already registered' });
      return;
    }

    const passwordHash = await bcrypt.hash(password, BCRYPT_ROUNDS);
    const result = await query(
      'INSERT INTO users (email, password_hash) VALUES ($1, $2) RETURNING id',
      [email, passwordHash]
    );
    const userId: string = result.rows[0].id;

    const tokens = signTokens(userId);

    await audit({
      userId,
      action: 'register',
      resourceType: 'user',
      resourceId: userId,
      ip: clientIp(req),
    });

    res.status(201).json(tokens);
  } catch (error) {
    if (error instanceof z.ZodError) {
      res.status(400).json({ error: 'Invalid input', details: error.errors });
      return;
    }
    console.error('[auth] register failed:', error);
    res.status(500).json({ error: 'Registration failed' });
  }
});

// ---------------------------------------------------------------------------
// POST /v1/auth/login
// ---------------------------------------------------------------------------

authRouter.post('/login', async (req: Request, res: Response) => {
  try {
    const { email, password } = LoginSchema.parse(req.body);

    const result = await query(
      'SELECT id, password_hash FROM users WHERE email = $1',
      [email]
    );
    if (result.rows.length === 0) {
      // Don't reveal whether the email exists
      res.status(401).json({ error: 'Invalid credentials' });
      return;
    }

    const user = result.rows[0];
    const valid = await bcrypt.compare(password, user.password_hash);
    if (!valid) {
      await audit({
        userId: user.id,
        action: 'login_failed',
        resourceType: 'user',
        ip: clientIp(req),
        detail: { reason: 'wrong_password' },
      });
      res.status(401).json({ error: 'Invalid credentials' });
      return;
    }

    const tokens = signTokens(user.id);

    await audit({
      userId: user.id,
      action: 'login',
      resourceType: 'user',
      resourceId: user.id,
      ip: clientIp(req),
    });

    res.json(tokens);
  } catch (error) {
    if (error instanceof z.ZodError) {
      res.status(400).json({ error: 'Invalid input', details: error.errors });
      return;
    }
    console.error('[auth] login failed:', error);
    res.status(401).json({ error: 'Invalid credentials' });
  }
});

// ---------------------------------------------------------------------------
// POST /v1/auth/refresh
// ---------------------------------------------------------------------------

authRouter.post('/refresh', async (req: Request, res: Response) => {
  try {
    const { refreshToken } = RefreshSchema.parse(req.body);

    const refreshSecret = process.env.JWT_REFRESH_SECRET;
    if (!refreshSecret) {
      res.status(500).json({ error: 'Server misconfiguration' });
      return;
    }

    const decoded = jwt.verify(refreshToken, refreshSecret) as { userId: string };

    // Verify the user still exists (they might have been deleted)
    const result = await query('SELECT id FROM users WHERE id = $1', [decoded.userId]);
    if (result.rows.length === 0) {
      res.status(401).json({ error: 'User not found' });
      return;
    }

    const tokens = signTokens(decoded.userId);

    await audit({
      userId: decoded.userId,
      action: 'token_refresh',
      resourceType: 'user',
      ip: clientIp(req),
    });

    res.json(tokens);
  } catch (error) {
    if (error instanceof z.ZodError) {
      res.status(400).json({ error: 'Refresh token required' });
      return;
    }
    res.status(401).json({ error: 'Invalid refresh token' });
  }
});
