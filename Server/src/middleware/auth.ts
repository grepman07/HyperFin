import { Request, Response, NextFunction } from 'express';
import jwt from 'jsonwebtoken';

// Augment Express Request so TypeScript knows about `req.user`
declare global {
  namespace Express {
    interface Request {
      user?: { userId: string };
    }
  }
}

/**
 * JWT authentication middleware.
 *
 * Verifies the Bearer token using `JWT_SECRET`, extracts `userId`, and
 * attaches it to `req.user`. Routes downstream can safely read
 * `req.user!.userId` after this middleware has run.
 */
export function requireAuth(req: Request, res: Response, next: NextFunction): void {
  const authHeader = req.headers.authorization;

  if (!authHeader?.startsWith('Bearer ')) {
    res.status(401).json({ error: 'Authorization header required' });
    return;
  }

  const token = authHeader.split(' ')[1];
  const secret = process.env.JWT_SECRET;

  if (!secret) {
    console.error('[auth] JWT_SECRET not configured');
    res.status(500).json({ error: 'Server misconfiguration' });
    return;
  }

  try {
    const decoded = jwt.verify(token, secret) as { userId: string };
    req.user = { userId: decoded.userId };
    next();
  } catch (err) {
    if (err instanceof jwt.TokenExpiredError) {
      res.status(401).json({ error: 'Token expired' });
    } else {
      res.status(401).json({ error: 'Invalid or expired token' });
    }
  }
}
